import Foundation
import Observation

public struct DownloadRecord: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case queued, downloading, completed, failed, cancelled }
    public let id: UUID
    public let plan: DownloadPlan
    public let createdAt: Date
    public var status: Status
    public var files: [String] = []
    public var error: String?
    public var folderName: String { "\(DownloadNaming.safe(plan.title))-\(id.uuidString)" }
}

@MainActor @Observable
public final class DownloadStore {
    public private(set) var records: [DownloadRecord] = []
    public private(set) var progress: DownloadProgress?
    public private(set) var currentFilename: String?
    public private(set) var errorMessage: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let downloader: any FileDownloading
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var tokens: [UUID: String] = [:]
    @ObservationIgnored private var isReadOnly = false

    public init(directory: URL, downloader: any FileDownloading = FileDownloader()) {
        self.directory = directory
        self.downloader = downloader
        let index = directory.appendingPathComponent(".history.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        do {
            records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: index))
            guard Set(records.map(\.id)).count == records.count,
                  records.allSatisfy({ record in record.plan.assets.allSatisfy { $0.name == DownloadNaming.safe($0.name) } }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for i in records.indices {
                if records[i].status == .downloading || records[i].status == .queued {
                    records[i].status = .failed
                    records[i].error = "上次下载已中断，点按重试重新下载。"
                    try? FileManager.default.removeItem(at: staging(records[i].id))
                }
                if records[i].status == .completed {
                    let folder = directory.appendingPathComponent(records[i].folderName)
                    if records[i].files.isEmpty || !records[i].files.allSatisfy({ $0 == DownloadNaming.safe($0) && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
                        records[i].status = .failed
                        records[i].error = DownloadError.missingFiles.localizedDescription
                    }
                }
            }
        } catch {
            isReadOnly = true
            errorMessage = "无法读取下载记录，已有文件保持不变：\(error.localizedDescription)"
        }
    }

    @discardableResult
    public func enqueue(_ plan: DownloadPlan, token: String? = nil) throws -> UUID {
        guard !isReadOnly else { throw CocoaError(.fileReadCorruptFile) }
        guard !plan.assets.isEmpty, Set(plan.assets.map(\.name)).count == plan.assets.count,
              plan.assets.allSatisfy({ $0.name == DownloadNaming.safe($0.name) }) else { throw DownloadError.invalidFile }
        if let existing = records.first(where: { $0.plan.key == plan.key }) {
            if existing.status == .completed { _ = try? fileURLs(for: existing) }
            try retry(existing.id, token: token)
            return existing.id
        }
        let record = DownloadRecord(id: UUID(), plan: plan, createdAt: Date(), status: .queued)
        records.insert(record, at: 0)
        do { try persist() }
        catch { records.removeAll { $0.id == record.id }; throw error }
        tokens[record.id] = token
        pump()
        return record.id
    }

    public func cancel(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if activeID == id { worker?.cancel() }
        else if records[index].status == .queued {
            records[index].status = .cancelled
            tokens[id] = nil
            saveState()
        }
    }

    public func retry(_ id: UUID, token: String? = nil) throws {
        guard !isReadOnly else { throw CocoaError(.fileReadCorruptFile) }
        guard let i = records.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(records[i].status) else { return }
        let previous = records[i]
        records[i].status = .queued
        records[i].error = nil
        records[i].files = []
        do { try persist() } catch { records[i] = previous; throw error }
        tokens[id] = token
        pump()
    }

    public func remove(_ id: UUID) throws {
        guard !isReadOnly else { throw CocoaError(.fileReadCorruptFile) }
        guard let record = records.first(where: { $0.id == id }), ![.queued, .downloading].contains(record.status) else { return }
        let folder = directory.appendingPathComponent(record.folderName)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        let previous = records
        records.removeAll { $0.id == id }
        do { try persist() } catch { records = previous; throw error }
    }

    public func fileURLs(for record: DownloadRecord) throws -> [URL] {
        let folder = directory.appendingPathComponent(record.folderName)
        let urls = record.files.filter { $0 == DownloadNaming.safe($0) }.map { folder.appendingPathComponent($0) }
        guard record.status == .completed, !urls.isEmpty, urls.count == record.files.count,
              urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            if record.status == .completed {
                update(record.id) { $0.status = .failed; $0.error = DownloadError.missingFiles.localizedDescription }
                saveState()
            }
            throw DownloadError.missingFiles
        }
        return urls
    }

    private func staging(_ id: UUID) -> URL { directory.appendingPathComponent(".partial-\(id.uuidString)") }

    private func pump() {
        guard worker == nil, let record = records.last(where: { $0.status == .queued }) else { return }
        activeID = record.id
        worker = Task { await run(record) }
    }

    private func run(_ record: DownloadRecord) async {
        let id = record.id
        let partial = staging(id)
        let final = directory.appendingPathComponent(record.folderName)
        defer {
            try? FileManager.default.removeItem(at: partial)
            tokens[id] = nil
            worker = nil
            activeID = nil
            progress = nil
            currentFilename = nil
            pump()
        }
        do {
            try Task.checkCancellation()
            update(id) { $0.status = .downloading; $0.error = nil }
            try persist()
            if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            var names: [String] = []
            for asset in record.plan.assets {
                try Task.checkCancellation()
                currentFilename = asset.name
                progress = nil
                let name: String
                if let content = asset.content {
                    name = asset.name
                    try content.write(to: partial.appendingPathComponent(name), options: .atomic)
                } else {
                    name = try await downloader.download(asset, to: partial, token: tokens[id]) { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.activeID == id, self.currentFilename == asset.name else { return }
                            self.progress = value
                        }
                    }
                }
                guard name == DownloadNaming.safe(name), !names.contains(name) else { throw DownloadError.invalidFile }
                names.append(name)
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
            try FileManager.default.moveItem(at: partial, to: final)
            update(id) { $0.status = .completed; $0.files = names }
            try persist()
        } catch {
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
            update(id) { $0.status = cancelled ? .cancelled : .failed; $0.error = cancelled ? nil : error.localizedDescription; $0.files = [] }
            saveState()
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent(".history.json"), options: .atomic)
    }
    private func saveState() {
        do { try persist() }
        catch { errorMessage = "下载记录保存失败：\(error.localizedDescription)" }
    }
}
