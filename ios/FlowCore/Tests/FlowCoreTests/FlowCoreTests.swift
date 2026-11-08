import Testing
import Foundation
import FlowCore

private func post(_ id: Int, extra: String = "") throws -> MediaPost {
    let json = """
    {"id":\(id),"url":"https://image.civitai.com/test/original=true/\(id).jpeg","nsfw":false,"browsingLevel":1\(extra)}
    """
    return try JSONDecoder().decode(MediaPost.self, from: Data(json.utf8))
}

struct ModelAndRequestTests {
    @Test func testVideoAndHeterogeneousPromptMetadata() throws {
        let data = Data("""
        {"items":[{"id":42,"url":"https://image.civitai.com/test.mp4","type":"video",
        "width":1080,"height":1920,"nsfwLevel":"None","browsingLevel":1,"nsfw":false,
        "thumbnail":{"url":"https://image.civitai.com/poster.jpeg"},
        "meta":{"prompt":"a mountain","negativePrompt":"blur","seed":3388724636,
        "cfgScale":7.5,"enabled":true,"resources":[{"type":"lora","weight":0.65}],"other":null}}],
        "metadata":{"nextCursor":"feed:123:42"}}
        """.utf8)
        let page = try JSONDecoder().decode(FeedPage.self, from: data)
        let item = try #require(page.items.first)
        #expect(item.isVideo)
        #expect(item.isSafeForWork)
        #expect(item.prompt == "a mountain")
        #expect(item.nonemptyMetadata("seed") == "3388724636")
        #expect(item.previewURL?.lastPathComponent == "poster.jpeg")
        #expect(item.aspectRatio == 0.5625)
        #expect(try JSONDecoder().decode(MediaPost.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test func testMissingMetadataAndUnsafeClassification() throws {
        let missing = try JSONDecoder().decode(MediaPost.self, from: Data(#"{"id":1,"url":"https://example.com/a.jpg"}"#.utf8))
        #expect(missing.prompt == nil)
        #expect(!(missing.isSafeForWork))
        #expect(missing.aspectRatio == 0.75)
        let unsafe = try JSONDecoder().decode(MediaPost.self, from: Data(#"{"id":2,"url":"https://example.com/a.jpg","nsfw":false,"browsingLevel":4}"#.utf8))
        #expect(!(unsafe.isSafeForWork))
    }

    @Test func testRequestPreservesOpaqueCursorAndEncodesUsername() throws {
        var query = FeedQuery()
        query.username = "  name+space &more  "
        query.media = .video
        query.sort = .newest
        let cursor = "feed:123:456|hello+world&value=3"
        let request = CivitaiClient().request(query: query, cursor: cursor, token: " key ")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "civitai.com")
        #expect(params["cursor"] == cursor)
        #expect(params["username"] == "name+space &more")
        #expect(params["type"] == "video")
        #expect(params["withMeta"] == "true")
        #expect(params["browsingLevel"] == "1")
        #expect(params["page"] == nil)
        #expect(!(url.absoluteString.contains("Bearer")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
        #expect(CivitaiClient().request(query: query, cursor: nil, token: "").value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func testOnlyCivitaiOriginalImagesGetResized() throws {
        #expect(try post(1).previewURL?.absoluteString == "https://image.civitai.com/test/width=600/1.jpeg")
        let external = try JSONDecoder().decode(MediaPost.self, from: Data(#"{"id":1,"url":"https://example.com/original=true/a.jpg"}"#.utf8))
        #expect(external.previewURL == external.url)
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let code = Int(token.replacingOccurrences(of: "Bearer ", with: "")) ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not valid JSON".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct HTTPClientTests {
    @Test func testHTTPFailuresAndMalformedJSONBecomeUsefulErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CivitaiClient(session: session)
        for (status, expected) in [(401, CivitaiError.authentication), (403, .authentication),
                                   (429, .rateLimited), (503, .http(503)), (200, .invalidResponse)] {
            do {
                _ = try await client.fetch(query: FeedQuery(), cursor: nil, token: String(status))
                Issue.record("Expected an error for HTTP \(status)")
            } catch let error as CivitaiError { #expect(error == expected) }
        }
    }
}

private actor QueueClient: FeedServing {
    var results: [Result<FeedPage, Error>]
    var cursors: [String?] = []
    init(_ results: [Result<FeedPage, Error>]) { self.results = results }
    func fetch(query: FeedQuery, cursor: String?, token: String?) async throws -> FeedPage {
        cursors.append(cursor)
        return try results.removeFirst().get()
    }
}

private actor DeferredClient: FeedServing {
    let old: FeedPage
    let new: FeedPage
    private var pending: CheckedContinuation<FeedPage, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(old: FeedPage, new: FeedPage) { self.old = old; self.new = new }
    func fetch(query: FeedQuery, cursor: String?, token: String?) async throws -> FeedPage {
        if query.sort == .newest { return new }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
    func waitForOldRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finishOldRequest() { pending?.resume(returning: old); pending = nil }
}

@MainActor
struct FeedStoreTests {
    @Test func testDeduplicatesPagesAndStopsRepeatedCursor() async throws {
        let first = try post(1), second = try post(2)
        let client = QueueClient([
            .success(FeedPage(items: [first, first], cursor: "a")),
            .success(FeedPage(items: [first, second], cursor: "a"))
        ])
        let store = FeedStore(client: client)
        await store.refresh(query: FeedQuery())
        await store.loadMore()
        #expect(store.posts.map(\.id) == [1, 2])
        #expect(!(store.hasMore))
        #expect(!(store.isLoadingMore))
        await store.loadMore()
        let requests = await client.cursors
        #expect(requests.count == 2)
    }

    @Test func testEmptyPageWithCursorDoesNotEndFeed() async throws {
        let client = QueueClient([
            .success(FeedPage(items: [], cursor: "a")),
            .success(FeedPage(items: [try post(2)]))
        ])
        let store = FeedStore(client: client)
        await store.refresh(query: FeedQuery())
        #expect(store.hasMore)
        await store.loadMore()
        #expect(store.posts.map(\.id) == [2])
        #expect(!(store.hasMore))
    }

    @Test func testRetryUsesSameCursorAndRetainsLoadedPosts() async throws {
        let client = QueueClient([
            .success(FeedPage(items: [try post(1)], cursor: "a")),
            .failure(CivitaiError.rateLimited),
            .success(FeedPage(items: [try post(2)]))
        ])
        let store = FeedStore(client: client)
        await store.refresh(query: FeedQuery())
        await store.loadMore()
        #expect(store.posts.map(\.id) == [1])
        #expect(store.errorMessage != nil)
        #expect(store.hasMore)
        await store.loadMore()
        #expect(store.posts.map(\.id) == [1, 2])
        #expect(store.errorMessage == nil)
        let requests = await client.cursors
        #expect(requests == [nil, "a", "a"])
    }

    @Test func testOldFilterResponseCannotReplaceNewFilter() async throws {
        let client = DeferredClient(old: FeedPage(items: [try post(1)]), new: FeedPage(items: [try post(2)]))
        let store = FeedStore(client: client)
        let oldTask = Task { await store.refresh(query: FeedQuery()) }
        await client.waitForOldRequest()
        var newest = FeedQuery()
        newest.sort = .newest
        await store.refresh(query: newest)
        await client.finishOldRequest()
        await oldTask.value
        #expect(store.posts.map(\.id) == [2])
        #expect(store.query.sort == .newest)
        #expect(!(store.isLoading))
    }

    @Test func testCancelledRequestDoesNotDisplayError() async throws {
        let client = DeferredClient(old: FeedPage(items: [try post(1)]), new: FeedPage(items: []))
        let store = FeedStore(client: client)
        let task = Task { await store.refresh(query: FeedQuery()) }
        await client.waitForOldRequest()
        task.cancel()
        await client.finishOldRequest()
        await task.value
        #expect(store.posts.isEmpty)
        #expect(store.errorMessage == nil)
        #expect(!(store.isLoading))
    }

    @Test func testUnsafeItemsAreRemovedEvenIfServerReturnsThem() async throws {
        let unsafe = try JSONDecoder().decode(MediaPost.self, from: Data(#"{"id":2,"url":"https://example.com/a.jpg","nsfw":true,"browsingLevel":1}"#.utf8))
        let client = QueueClient([.success(FeedPage(items: [try post(1), unsafe]))])
        let store = FeedStore(client: client)
        await store.refresh(query: FeedQuery())
        #expect(store.posts.map(\.id) == [1])
    }

    @Test func testUnsupportedAudioItemsAreNotPresentedAsImages() async throws {
        let audio = try post(2, extra: #", "type":"audio""#)
        let client = QueueClient([.success(FeedPage(items: [try post(1), audio]))])
        let store = FeedStore(client: client)
        await store.refresh(query: FeedQuery())
        #expect(store.posts.map(\.id) == [1])
    }
}

@MainActor
struct LibraryStoreTests {
    @Test func testBookmarksSurviveRelaunchAndToggleRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("saved.json")
        let first = LibraryStore(fileURL: file)
        let item = try post(42, extra: #", "meta":{"prompt":"mountains"}"#)
        try first.toggle(item)
        let second = LibraryStore(fileURL: file)
        #expect(second.posts == [item])
        try second.toggle(item)
        #expect(LibraryStore(fileURL: file).posts.isEmpty)
    }

    @Test func testCorruptedLibraryIsNotOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("not-json".utf8)
        try original.write(to: file)
        let store = LibraryStore(fileURL: file)
        #expect(store.errorMessage != nil)
        #expect(throws: (any Error).self) { try store.toggle(post(1)) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func testFailedWriteDoesNotClaimBookmarkWasSaved() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("a file, not a folder".utf8).write(to: parent)
        let store = LibraryStore(fileURL: parent.appendingPathComponent("saved.json"))
        #expect(throws: (any Error).self) { try store.toggle(post(1)) }
        #expect(store.posts.isEmpty)
    }
}

@MainActor
struct LiveAPITests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOW_LIVE_API"] == "1"))
    func testPublicImagesAndVideoEndpoint() async throws {
        for filter in [MediaFilter.image, .video] {
            var query = FeedQuery()
            query.media = filter
            let page = try await CivitaiClient().fetch(query: query, cursor: nil, token: nil)
            #expect(!(page.items.isEmpty))
            #expect(page.items.allSatisfy { $0.isVideo == (filter == .video) })
            // The live service can return an out-of-filter item even with browsingLevel=1.
            // Verify what the app presents, rather than assuming the server always filters.
            let store = FeedStore(client: QueueClient([.success(page)]))
            await store.refresh(query: query)
            #expect(!store.posts.isEmpty)
            #expect(store.posts.allSatisfy { $0.browsingLevel == 1 && $0.nsfw != true })
            let rejectedIDs = Set(page.items.filter { $0.browsingLevel != 1 || $0.nsfw == true }.map(\.id))
            #expect(Set(store.posts.map(\.id)).isDisjoint(with: rejectedIDs))
            if let cursor = page.metadata?.nextCursor {
                _ = try await CivitaiClient().fetch(query: query, cursor: cursor, token: nil)
            }
        }
    }
}
