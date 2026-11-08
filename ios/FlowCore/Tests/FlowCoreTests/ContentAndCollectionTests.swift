import Testing
import Foundation
import FlowCore

private func ratedPost(_ id: Int, level: Int = 1, video: Bool = false) throws -> MediaPost {
    try JSONDecoder().decode(MediaPost.self, from: Data("""
    {"id":\(id),"url":"https://image.civitai.com/test/\(id).\(video ? "mp4" : "jpg")","type":"\(video ? "video" : "image")","browsingLevel":\(level),"nsfw":\(level > 1)}
    """.utf8))
}

struct ContentPreferenceTests {
    @Test func exactDisjointRatingsAndPG13LegacyFlag() throws {
        for level in ContentRating.allCases {
            let post = try ratedPost(level.rawValue, level: level.rawValue)
            #expect(post.contentRating == level)
            #expect(post.isAllowed(ratings: level.rawValue))
            #expect(!post.isAllowed(ratings: ContentRating.allMask ^ level.rawValue))
            #expect(!post.isAllowed(ratings: 0))
        }
        #expect(try ratedPost(32, level: 32).contentRating == nil)
        #expect(try ratedPost(64, level: 3).contentRating == nil)
        let pg13 = try JSONDecoder().decode(MediaPost.self, from: Data(#"{"id":1,"url":"https://example.com/a.jpg","nsfw":true,"nsfwLevel":"Soft"}"#.utf8))
        #expect(pg13.contentRating == .pg13)
    }

    @Test func ratingMaskAndTypedSearchUseEncodedParameters() throws {
        var query = FeedQuery(); query.ratings = 1 | 4 | 16
        let request = CivitaiClient().request(query: query, cursor: nil, token: nil)
        let requestURL = try #require(request.url)
        let parameters = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(parameters.first { $0.name == "browsingLevel" }?.value == "21")
        #expect(!parameters.contains { $0.name == "nsfw" })
        let url = SearchTarget.articles.url(query: "  a+b &猫  ")
        #expect(url.path == "/search/articles")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a+b &猫")
        #expect(DiscoverSection.models3d.url.path == "/3d-models")
    }
}

private actor CollectionStub: CollectionServing {
    var user: CollectionAccount
    var folders: [RemoteCollection]
    var items: [Int: [MediaPost]]
    var writes: [(Int, Int, Bool)] = []
    var shouldFail: Bool
    var created = 100
    init(userID: Int = 1, folders: [RemoteCollection] = [], items: [Int: [MediaPost]] = [:], fail: Bool = false) {
        user = CollectionAccount(id: userID, username: "user\(userID)")
        self.folders = folders; self.items = items; shouldFail = fail
    }
    func account(token: String) async throws -> CollectionAccount { user }
    func collections(token: String) async throws -> [RemoteCollection] { folders }
    func create(name: String, token: String) async throws -> RemoteCollection {
        if shouldFail { throw CivitaiError.http(503) }
        created += 1
        let folder = RemoteCollection(id: created, name: name, userId: user.id)
        folders.append(folder)
        return folder
    }
    func save(postID: Int, collectionID: Int, included: Bool, token: String) async throws {
        if shouldFail { throw CivitaiError.http(503) }
        writes.append((postID, collectionID, included))
        items[collectionID, default: []].removeAll { $0.id == postID }
        if included { items[collectionID, default: []].append(try ratedPost(postID)) }
    }
    func media(in collectionID: Int, token: String) async throws -> [MediaPost] {
        if shouldFail { throw CivitaiError.http(503) }
        return items[collectionID] ?? []
    }
}

@MainActor struct CollectionStoreTests {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }
    @Test func legacyMigrationAndMultipleMembershipsSurviveRelaunch() throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let post = try ratedPost(1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([post]).write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.collections.count == 1)
        let folder = try store.createCollection(name: "风景")
        try store.save(post, to: store.collectionIDs(for: post).union([folder]))
        let reloaded = LibraryStore(fileURL: url)
        #expect(reloaded.collectionIDs(for: post).count == 2)
        try reloaded.save(post, to: [folder])
        #expect(reloaded.contains(post))
        #expect(reloaded.posts(in: folder) == [post])
        try reloaded.save(post, to: [])
        #expect(!LibraryStore(fileURL: url).contains(post))
    }

    @Test func uploadsLocalFoldersAndImportsRemoteMemberships() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let post = try ratedPost(1), incoming = try ratedPost(2, video: true)
        let client = CollectionStub(folders: [RemoteCollection(id: 9, name: "网站收藏", userId: 1)], items: [9: [incoming]])
        let store = LibraryStore(fileURL: url)
        let a = try store.createCollection(name: "A"), b = try store.createCollection(name: "B")
        try store.save(post, to: [a,b])
        await store.sync(token: "test", client: client)
        #expect(store.syncError == nil)
        #expect(store.lastSyncedAt != nil)
        #expect(store.pendingCount == 0)
        #expect(store.collectionIDs(for: post).count == 2)
        #expect(store.contains(incoming))
        #expect(store.posts.count == 2)
        let writes = await client.writes
        #expect(writes.count == 2)
        try store.save(post, to: [b])
        await store.sync(token: "test", client: client)
        #expect(store.collectionIDs(for: post) == [b])
        let nextWrites = await client.writes
        #expect(nextWrites.count == 3)
        #expect(nextWrites.last?.2 == false)
        #expect(LibraryStore(fileURL: url).collectionIDs(for: post) == [b])
    }

    @Test func failedSyncKeepsDurableChangesForRetryAndAccountSwitchIsIsolated() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let post = try ratedPost(3)
        let failing = CollectionStub(fail: true)
        let store = LibraryStore(fileURL: url)
        try store.toggle(post)
        await store.sync(token: "test", client: failing)
        #expect(store.syncError != nil)
        #expect(store.contains(post))
        #expect(LibraryStore(fileURL: url).pendingCount == 1)
        let first = CollectionStub()
        await store.sync(token: "first", client: first)
        #expect(store.pendingCount == 0)
        let second = CollectionStub(userID: 2)
        await store.sync(token: "second", client: second)
        #expect(!store.contains(post))
        #expect(await second.writes.isEmpty)
        await store.sync(token: "first", client: first)
        #expect(store.contains(post))
        store.disconnect()
        #expect(store.contains(post))
    }

    @Test func websiteRemovalsAndFolderDeletionAreReflected() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let post = try ratedPost(4)
        let original = CollectionStub(folders: [RemoteCollection(id: 8, name: "网站", userId: 1)], items: [8: [post]])
        let store = LibraryStore(fileURL: url)
        await store.sync(token: "test", client: original)
        #expect(store.contains(post))
        let removed = CollectionStub(folders: [RemoteCollection(id: 8, name: "改名", userId: 1)])
        await store.sync(token: "test", client: removed)
        #expect(!store.contains(post))
        #expect(store.collections.first?.name == "改名")
        await store.sync(token: "test", client: CollectionStub())
        #expect(store.collections.isEmpty)
    }
}

private final class CollectionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200, body = ""
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture" { status = 401 }
        else if path == "/api/v1/me" { body = #"{"id":7,"username":"fixture-user"}"# }
        else if path.hasSuffix("collection.getAllUser") {
            body = #"{"result":{"data":{"json":[{"id":10,"name":"Cloud","userId":7,"type":"Image"}]}}}"#
        } else if path.hasSuffix("collection.upsert") {
            if request.httpMethod != "POST" || request.value(forHTTPHeaderField: "Content-Type") != "application/json" { status = 400 }
            body = #"{"result":{"data":{"json":{"id":11,"name":"New","userId":7,"type":"Image"}}}}"#
        } else if path.hasSuffix("collection.saveItem") {
            if request.httpMethod != "POST" { status = 400 }
            body = #"{"result":{"data":{"json":"added"}}}"#
        } else if path.hasSuffix("collection.getAllCollectionItems") {
            let input = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            if input.contains("cursor") { body = #"{"result":{"data":{"json":{"collectionItems":[{"type":"image","data":{"id":2}}],"nextCursor":null}}}}"# }
            else { body = #"{"result":{"data":{"json":{"collectionItems":[{"type":"image","data":{"id":1}}],"nextCursor":"next:1"}}}}"# }
        } else if path == "/api/v1/images" {
            body = #"{"items":[{"id":1,"url":"https://image.civitai.com/a.jpg","browsingLevel":1},{"id":2,"url":"https://image.civitai.com/b.mp4","browsingLevel":2,"type":"video"}]}"#
        } else { status = 404 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct CollectionTransportTests {
    @Test func actualTransportHandlesEnvelopesMutationAndPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollectionURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = CollectionClient(session: session)
        #expect(try await client.account(token: "fixture").id == 7)
        #expect(try await client.collections(token: "fixture").first?.id == 10)
        #expect(try await client.create(name: "New", token: "fixture").id == 11)
        try await client.save(postID: 1, collectionID: 10, included: true, token: "fixture")
        try await client.save(postID: 1, collectionID: 10, included: false, token: "fixture")
        #expect(try await client.media(in: 10, token: "fixture").map(\.id) == [1,2])
        do { _ = try await client.account(token: "bad"); Issue.record("Expected authentication failure") }
        catch { #expect(error as? CivitaiError == .authentication) }
    }
}
