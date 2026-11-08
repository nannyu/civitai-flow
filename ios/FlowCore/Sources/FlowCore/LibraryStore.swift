import Foundation
import Observation

@MainActor @Observable
public final class LibraryStore {
    public private(set) var posts: [MediaPost] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var loadFailed = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { posts = try JSONDecoder().decode([MediaPost].self, from: Data(contentsOf: fileURL)) }
        catch {
            loadFailed = true
            errorMessage = "收藏文件读取失败，原文件已保留。请先备份或恢复文件，再重新打开应用。"
        }
    }

    public func contains(_ post: MediaPost) -> Bool { posts.contains { $0.id == post.id } }

    public func toggle(_ post: MediaPost) throws {
        guard !loadFailed else { throw LibraryError.unreadable }
        var updated = posts
        if contains(post) { updated.removeAll { $0.id == post.id } }
        else { updated.insert(post, at: 0) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            try data.write(to: fileURL, options: .atomic)
            posts = updated
            errorMessage = nil
        } catch {
            errorMessage = "收藏保存失败，请检查设备的可用空间。"
            throw error
        }
    }

    public enum LibraryError: LocalizedError {
        case unreadable
        public var errorDescription: String? { "收藏文件无法读取，已停止写入以保护现有收藏。" }
    }
}
