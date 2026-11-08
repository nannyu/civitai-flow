import Foundation
import Testing
@testable import FlowCore

private let versionFixture = Data(#"""
{"id":9,"modelId":7,"name":"v2","baseModel":"SDXL 1.0","description":"<p>Version &amp; notes</p>",
 "unknownFutureField":{"keep":true},"files":[
 {"id":1,"name":"example.safetensors","type":"Model","sizeKB":1024,"primary":true,
 "metadata":{"format":"SafeTensor","fp":"fp16"},"downloadUrl":"https://civitai.com/api/download/models/9?type=Model&format=SafeTensor&fp=fp16"},
 {"id":2,"name":"training.zip","type":"Training Data","downloadUrl":"https://civitai.com/api/download/models/9?type=Training%20Data"}],
 "images":[
 {"url":"https://image.civitai.com/id/width=450/video.mp4","width":450,"type":"video","nsfwLevel":1},
 {"url":"https://image.civitai.com/id/width=600/unsafe.jpg","width":1200,"type":"image","nsfwLevel":2},
 {"url":"https://image.civitai.com/id/width=600/preview.jpg","width":1024,"type":"image","nsfwLevel":1}]}
"""#.utf8)

private let pngFixture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")!

struct DownloadPlanTests {
    @Test func modelLinksPreserveVersionAndFileSelectionWithoutCredentials() throws {
        let link = try ModelLink(" https://civitai.com/models/7/example?modelVersionId=9&token=secret ")
        #expect(link.modelID == 7 && link.versionID == 9)
        let direct = try ModelLink("https://civitai.com/api/download/models/9?type=Model&format=SafeTensor&fp=fp16&token=secret")
        #expect(direct.modelID == nil && direct.versionID == 9)
        #expect(direct.fileQuery == ["type": "Model", "format": "SafeTensor", "fp": "fp16"])
        #expect(try ModelLink("https://civitai.green/models/7").modelID == 7)
        for input in ["http://civitai.com/models/7", "https://civitai.com.evil.test/models/7", "https://user@civitai.com/models/7",
                      "https://civitai.com/models/7?modelVersionId=nope", "https://civitai.com/models/-1", "https://civitai.com/images/7"] {
            #expect(throws: DownloadError.invalidLink) { try ModelLink(input) }
        }
    }

    @Test func modelBundlePreservesMetadataAndPicksSafeImageAfterVideo() throws {
        let document = try ModelVersionDocument(data: versionFixture)
        let file = try #require(document.version.downloadableFiles.first)
        #expect(document.version.downloadableFiles.count == 1)
        #expect(file.matches(["fp": "fp16"]))
        #expect(!file.matches(["fp": "fp32"]))
        let plan = try DownloadPlan.model(document, file: file, modelDescription: "<p>Model description</p>")
        #expect(plan.assets.map(\.name) == ["example.safetensors", "example.civitai.info", "example.preview.jpg", "example.description.txt"])
        #expect(plan.assets[2].url?.absoluteString == "https://image.civitai.com/id/original=true/preview.jpg")
        let metadata = try #require(JSONSerialization.jsonObject(with: plan.assets[1].content!) as? [String: Any])
        #expect((metadata["unknownFutureField"] as? [String: Bool])?["keep"] == true)
        #expect(String(decoding: plan.assets[3].content!, as: UTF8.self) == "Model description\n\nVersion & notes")
        #expect(throws: DownloadError.noFiles) { try DownloadPlan.model(document, file: document.version.files[1]) }
    }

    @Test func modelOptionsSupportVideoPreviewAndOmittingSidecars() throws {
        let document = try ModelVersionDocument(data: versionFixture)
        var options = DownloadOptions()
        options.imagePreviewOnly = false
        let video = try DownloadPlan.model(document, file: document.version.files[0], options: options)
        #expect(video.assets[2].kind == .video)
        #expect(video.assets[2].name == "example.preview.mp4")
        #expect(video.assets[2].url?.path.contains("width=450") == true)
        options.includePreview = false
        options.includeDescription = false
        #expect(try DownloadPlan.model(document, file: document.version.files[0], options: options).assets.count == 2)
    }

    @Test func missingSidecarsHaveAnExplicitNote() throws {
        let json = String(decoding: versionFixture, as: UTF8.self)
            .replacingOccurrences(of: "\"nsfwLevel\":1", with: "\"nsfwLevel\":4")
            .replacingOccurrences(of: "<p>Version &amp; notes</p>", with: "")
        let document = try ModelVersionDocument(data: Data(json.utf8))
        let plan = try DownloadPlan.model(document, file: document.version.files[0])
        #expect(plan.assets.count == 2)
        #expect(plan.notes.count == 2)
    }

    @Test func filenamesCannotEscapeFolderAndRetainExtensions() {
        #expect(!DownloadNaming.safe("../../evil\\file.safetensors").contains("/"))
        #expect(!DownloadNaming.safe("../../evil\\file.safetensors").contains("\\"))
        #expect(DownloadNaming.safe("...") == "download")
        let long = DownloadNaming.safe(String(repeating: "模型", count: 100) + ".safetensors")
        #expect(long.utf8.count <= 180)
        #expect(long.hasSuffix(".safetensors"))
    }

    @Test func mediaBundlesKeepMetadataAndDeduplicateModelReferences() throws {
        let post = try JSONDecoder().decode(MediaPost.self, from: Data(#"""
        {"id":42,"url":"https://image.civitai.com/id/width=450/a.png","type":"image",
         "meta":{"prompt":"a landscape","civitaiResources":[{"modelVersionId":9}],
         "resources":[{"versionId":"9","name":"duplicate"},{"modelVersionId":10,"name":"LoRA"},{"hash":"unknown"}]}}
        """#.utf8))
        let plan = try DownloadPlan.media(post)
        #expect(plan.assets.first?.url?.path == "/id/original=true/a.png")
        #expect(plan.assets.count == 2)
        #expect(try JSONDecoder().decode(MediaPost.self, from: plan.assets[1].content!) == post)
        #expect(post.modelResources.map(\.id) == [9, 10])
        #expect(post.modelResources[1].name == "LoRA")
        let external = URL(string: "https://example.com/id/width=400/a.jpg")!
        #expect(DownloadNaming.originalMediaURL(external, isVideo: false) == external)
    }
}

struct DownloadHTTPTests {
    @Test func credentialsOnlyGoToCivitaiAPIAndAreRemovedOnRedirect() throws {
        let url = URL(string: "https://civitai.com/api/download/models/9")!
        let request = try DownloadHTTP.request(url: url, token: " secret ")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(!request.url!.absoluteString.contains("secret"))
        let cdn = URL(string: "https://storage.example.com/model")!
        #expect(try DownloadHTTP.request(url: cdn, token: "secret").value(forHTTPHeaderField: "Authorization") == nil)
        var redirected = request
        redirected.url = cdn
        redirected.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let safe = DownloadHTTP.redirected(redirected, from: url)
        #expect(safe?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(safe?.value(forHTTPHeaderField: "Cookie") == nil)
        redirected.url = URL(string: "http://storage.example.com/model")!
        #expect(DownloadHTTP.redirected(redirected, from: url) == nil)
        #expect(throws: DownloadError.unsafeURL) { try DownloadHTTP.request(url: redirected.url!, token: "secret") }
        let withToken = URL(string: "https://civitai.com/api/download/models/9?type=Model&token=secret")!
        #expect(try DownloadHTTP.modelURL(withToken, versionID: 9).query == "type=Model")
        #expect(throws: DownloadError.unsafeURL) { try DownloadHTTP.modelURL(url, versionID: 10) }
    }

    @Test func fileValidationCorrectsExtensionsAndRejectsErrorPagesAndTruncation() throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let url = URL(string: "https://image.civitai.com/a.jpg")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        try pngFixture.write(to: local)
        #expect(try FileDownloader.validatedFilename("a.jpg", kind: .image, response: response, file: local) == "a.png")
        let truncated = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "999"])!
        #expect(throws: DownloadError.invalidFile) { try FileDownloader.validatedFilename("a.png", kind: .image, response: truncated, file: local) }
        try Data("<!DOCTYPE html><html>Login</html>".utf8).write(to: local)
        #expect(throws: DownloadError.invalidFile) { try FileDownloader.validatedFilename("model.safetensors", kind: .model, response: response, file: local) }
        try Data().write(to: local)
        #expect(throws: DownloadError.invalidFile) { try FileDownloader.validatedFilename("a.png", kind: .image, response: response, file: local) }
    }

    @Test func videoBytesAreNotMislabeledAsImages() throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let response = URLResponse(url: URL(string: "https://image.civitai.com/a.mp4")!, mimeType: "video/mp4", expectedContentLength: -1, textEncodingName: nil)
        try (Data([0, 0, 0, 24]) + Data("ftypisom0000".utf8)).write(to: local)
        #expect(try FileDownloader.validatedFilename("a.webm", kind: .video, response: response, file: local) == "a.mp4")
        #expect(throws: DownloadError.invalidFile) { try FileDownloader.validatedFilename("a.png", kind: .image, response: response, file: local) }
    }
}

private final class DownloadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code = Int(request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? "") ?? 200
        let url = request.url!
        let body: Data
        let mime: String
        if url.path.contains("model-versions") { body = versionFixture; mime = "application/json" }
        else if url.path.contains("/models/") {
            body = Data(#"{"id":7,"name":"Example","modelVersions":[{"id":9,"name":"v2"}]}"#.utf8); mime = "application/json"
        } else if url.path.contains("bad") { body = Data("<html>login</html>".utf8); mime = "text/html" }
        else { body = pngFixture; mime = "image/png" }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ModelDownloadClientTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func modelMetadataAndHTTPFailuresUseActualTransport() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = ModelClient(session: session)
        #expect(try await client.catalog(id: 7, token: nil).modelVersions.first?.id == 9)
        #expect(try await client.version(id: 9, token: nil).version.files.count == 2)
        for (status, expected) in [(401, CivitaiError.authentication), (403, .authentication), (429, .rateLimited), (503, .http(503))] {
            await #expect(throws: expected) { try await client.version(id: 9, token: String(status)) }
        }
        await #expect(throws: CivitaiError.invalidResponse) { try await client.version(id: 123, token: nil) }
    }

    @Test func fileTransportWritesValidatedBytesAndCleansFailures() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = FileDownloader(session: session)
        let asset = DownloadAsset(name: "preview.jpg", url: URL(string: "https://image.civitai.com/preview.jpg")!, kind: .image)
        let name = try await client.download(asset, to: dir, token: "secret") { _ in }
        #expect(name == "preview.png")
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == pngFixture)
        let bad = DownloadAsset(name: "bad.jpg", url: URL(string: "https://image.civitai.com/bad.jpg")!, kind: .image)
        await #expect(throws: DownloadError.invalidFile) { try await client.download(bad, to: dir, token: nil) { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["preview.png"])
    }
}

private actor ControlledDownloader: FileDownloading {
    enum Outcome { case success, failure, wait }
    var outcomes: [Outcome]
    var calls: [String] = []
    var tokens: [String?] = []
    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
    func download(_ asset: DownloadAsset, to directory: URL, token: String?, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> String {
        calls.append(asset.name); tokens.append(token)
        let next = outcomes.isEmpty ? .success : outcomes.removeFirst()
        try Data("downloaded content".utf8).write(to: directory.appendingPathComponent(asset.name))
        progress(DownloadProgress(received: 5, expected: 10))
        switch next {
        case .success: return asset.name
        case .failure: throw CivitaiError.http(503)
        case .wait: try await Task.sleep(for: .seconds(30)); return asset.name
        }
    }
}

@MainActor
struct DownloadStoreTests {
    private func plan(_ key: String = "one") -> DownloadPlan {
        DownloadPlan(key: key, title: "Example", assets: [
            DownloadAsset(name: "model.safetensors", url: URL(string: "https://civitai.com/api/download/models/9")!, kind: .model),
            DownloadAsset(name: "model.civitai.info", content: Data("metadata".utf8))
        ])
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("Download state did not settle"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func completedBundleRestoresAndDeduplicatesWithoutPersistingToken() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = ControlledDownloader([.success])
        let store = DownloadStore(directory: dir, downloader: downloader)
        let id = try store.enqueue(plan(), token: "private-token")
        #expect(try store.enqueue(plan()) == id)
        try await waitUntil { store.records.first?.status == .completed }
        let restored = DownloadStore(directory: dir)
        let record = try #require(restored.records.first)
        #expect(record.status == .completed)
        let files = try restored.fileURLs(for: record)
        #expect(files.count == 2)
        #expect(try Data(contentsOf: files[1]) == Data("metadata".utf8))
        let history = try String(contentsOf: dir.appendingPathComponent(".history.json"), encoding: .utf8)
        #expect(!history.contains("private-token"))
        #expect(await downloader.tokens == ["private-token"])
        #expect(try restored.enqueue(plan()) == id)
        try restored.remove(id)
        #expect(restored.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
    }

    @Test func failedPartialBundleIsRemovedAndRetryUsesNewToken() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = ControlledDownloader([.failure, .success])
        let store = DownloadStore(directory: dir, downloader: downloader)
        let id = try store.enqueue(plan(), token: "old")
        try await waitUntil { store.records.first?.status == .failed }
        #expect(store.records.first?.error != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".history.json"])
        try store.retry(id, token: "new")
        try await waitUntil { store.records.first?.status == .completed }
        #expect(await downloader.tokens == ["old", "new"])
    }

    @Test func cancellingActiveAndQueuedJobsStopsTransfersAndAllowsRetry() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = ControlledDownloader([.wait, .success])
        let store = DownloadStore(directory: dir, downloader: downloader)
        let first = try store.enqueue(plan("first"))
        let second = try store.enqueue(plan("second"))
        try await waitUntil { store.progress != nil }
        #expect(store.progress?.fraction == 0.5)
        store.cancel(second); store.cancel(first)
        try await waitUntil { store.records.allSatisfy { $0.status == .cancelled } }
        #expect(await downloader.calls.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".history.json"])
        try store.retry(first)
        try await waitUntil { store.records.first(where: { $0.id == first })?.status == .completed }
    }

    @Test func queueContinuesAfterFailureAndMissingFileCanBeDownloadedAgain() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(directory: dir, downloader: ControlledDownloader([.failure, .success, .success]))
        _ = try store.enqueue(plan("first"))
        let id = try store.enqueue(plan("second"))
        try await waitUntil { store.records.first(where: { $0.id == id })?.status == .completed }
        let record = try #require(store.records.first(where: { $0.id == id }))
        try FileManager.default.removeItem(at: store.fileURLs(for: record)[0])
        #expect(throws: DownloadError.missingFiles) { try store.fileURLs(for: record) }
        #expect(store.records.first(where: { $0.id == id })?.status == .failed)
        #expect(try store.enqueue(plan("second")) == id)
        try await waitUntil { store.records.first(where: { $0.id == id })?.status == .completed }
    }

    @Test func interruptedRecordsRecoverAsRetryableAndCorruptHistoryIsProtected() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = DownloadRecord(id: UUID(), plan: plan(), createdAt: Date(), status: .downloading)
        let index = dir.appendingPathComponent(".history.json")
        try JSONEncoder().encode([record]).write(to: index)
        let partial = dir.appendingPathComponent(".partial-\(record.id.uuidString)")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let restored = DownloadStore(directory: dir)
        #expect(restored.records.first?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let corrupt = Data("broken history".utf8)
        try corrupt.write(to: index)
        let blocked = DownloadStore(directory: dir)
        #expect(blocked.errorMessage != nil)
        #expect(throws: (any Error).self) { try blocked.enqueue(plan()) }
        #expect(try Data(contentsOf: index) == corrupt)
    }

    @Test func failedDiskWriteDoesNotClaimJobWasQueued() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("file not directory".utf8).write(to: dir)
        let store = DownloadStore(directory: dir)
        #expect(throws: (any Error).self) { try store.enqueue(plan()) }
        #expect(store.records.isEmpty)
    }
}
