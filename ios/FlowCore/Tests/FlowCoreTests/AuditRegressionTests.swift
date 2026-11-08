import Testing
import Foundation
import FlowCore

private func auditPost(_ id: Int, rating: Int = 1) throws -> MediaPost {
    try JSONDecoder().decode(MediaPost.self, from: Data("""
    {"id":\(id),"url":"https://image.civitai.com/test/original=true/\(id).jpg","browsingLevel":\(rating),"nsfw":\(rating > 1)}
    """.utf8))
}

private actor AuditServer: CollectionServing {
    let userID: Int
    var folders: [RemoteCollection]
    var items: [Int: [MediaPost]]
    var ids: [Int: Set<Int>] = [:]
    var lag = false
    var creationFails = false
    var creates = 0
    var writes = 0
    var holdAccount = false
    var holdSnapshot = false
    var held: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(userID: Int = 1, folders: [RemoteCollection] = [], items: [Int: [MediaPost]] = [:]) {
        self.userID = userID; self.folders = folders; self.items = items
    }
    func account(token: String) async throws -> CollectionAccount {
        if holdAccount { await suspend() }
        return CollectionAccount(id: userID, username: "user\(userID)")
    }
    func collections(token: String) async throws -> [RemoteCollection] { folders }
    func create(name: String, token: String) async throws -> RemoteCollection {
        if creationFails { throw CivitaiError.http(503) }
        creates += 1
        let folder = RemoteCollection(id: 100 + creates, name: name, userId: userID)
        folders.append(folder)
        return folder
    }
    func save(postID: Int, collectionID: Int, included: Bool, token: String) async throws {
        writes += 1
        if !lag {
            items[collectionID, default: []].removeAll { $0.id == postID }
            if included { items[collectionID, default: []].append(try auditPost(postID)) }
        }
    }
    func media(in collectionID: Int, token: String) async throws -> [MediaPost] { items[collectionID] ?? [] }
    func snapshot(in collectionID: Int, token: String) async throws -> CollectionMediaSnapshot {
        let posts = items[collectionID] ?? []
        let snapshot = CollectionMediaSnapshot(ids: ids[collectionID] ?? Set(posts.map(\.id)), posts: posts)
        if holdSnapshot { holdSnapshot = false; await suspend() }
        return snapshot
    }
    func configure(lag: Bool = false, creationFails: Bool = false, holdAccount: Bool = false, holdSnapshot: Bool = false) {
        self.lag = lag; self.creationFails = creationFails; self.holdAccount = holdAccount; self.holdSnapshot = holdSnapshot
    }
    func replace(folderID: Int, posts: [MediaPost], ids: Set<Int>? = nil) { items[folderID] = posts; self.ids[folderID] = ids }
    func waitUntilHeld() async { if held == nil { await withCheckedContinuation { waiters.append($0) } } }
    func release() { held?.resume(); held = nil }
    private func suspend() async {
        await withCheckedContinuation { continuation in
            held = continuation; waiters.forEach { $0.resume() }; waiters = []
        }
    }
}

@MainActor struct CollectionAuditTests {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("saved.json") }

    @Test func delayedReadAfterWriteCannotEraseASavedPostOrItsRemoval() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let server = AuditServer(), store = LibraryStore(fileURL: file), post = try auditPost(1)
        let folder = try store.createCollection(name: "A")
        try store.save(post, to: [folder])
        await server.configure(lag: true)
        await store.sync(token: "fixture", client: server)
        #expect(store.contains(post)); #expect(store.pendingCount == 1)
        #expect(LibraryStore(fileURL: file).contains(post))
        await server.configure()
        await store.sync(token: "fixture", client: server)
        #expect(store.pendingCount == 0)
        try store.save(post, to: [])
        await server.configure(lag: true)
        await store.sync(token: "fixture", client: server)
        #expect(!store.contains(post)); #expect(store.pendingCount == 1)
        await server.configure()
        await store.sync(token: "fixture", client: server)
        #expect(!store.contains(post)); #expect(store.pendingCount == 0)
    }

    @Test func offlineFolderCannotBeUploadedIntoADifferentAccount() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: file), first = AuditServer(), second = AuditServer(userID: 2)
        await store.sync(token: "a", client: first)
        let folder = try store.createCollection(name: "A offline")
        try store.save(auditPost(2), to: [folder])
        await store.sync(token: "b", client: second)
        #expect(await second.creates == 0); #expect(await second.writes == 0)
        #expect(store.pendingCount == 0); #expect(store.availableCollections.isEmpty)
        await store.sync(token: "a", client: first)
        #expect(store.contains(try auditPost(2))); #expect(store.pendingCount == 0)
    }

    @Test func failedFirstUploadStillClaimsUnboundDataForTheFirstAccount() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: file), first = AuditServer(), second = AuditServer(userID: 2)
        try store.toggle(auditPost(3))
        await first.configure(creationFails: true)
        await store.sync(token: "a", client: first)
        #expect(store.syncError != nil)
        await store.sync(token: "b", client: second)
        #expect(await second.creates == 0); #expect(await second.writes == 0)
        #expect(store.collections.first?.ownerID == 1)
    }

    @Test func disconnectInvalidatesAnInflightAccountResponse() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: file), first = AuditServer(), delayed = AuditServer(userID: 2)
        await store.sync(token: "a", client: first)
        await delayed.configure(holdAccount: true)
        let syncing = Task { await store.sync(token: "b", client: delayed) }
        await delayed.waitUntilHeld()
        store.disconnect()
        await delayed.release(); await syncing.value
        #expect(store.account?.id == 1); #expect(store.lastSyncedAt == nil)
        #expect(store.syncError == nil); #expect(!store.isSyncing)
    }

    @Test func pickerChangesPreserveMembershipsAddedAfterThePickerOpened() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: file), post = try auditPost(4)
        let a = try store.createCollection(name: "A"), b = try store.createCollection(name: "B")
        try store.save(post, to: [a])
        let baseline = store.collectionIDs(for: post)
        try store.save(post, to: [a,b])
        try store.save(post, to: [], replacing: baseline)
        #expect(store.collectionIDs(for: post) == [b])
    }

    @Test func localEditsDuringReadDoNotDiscardNewCloudMembers() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteCollection(id: 8, name: "Cloud", userId: 1)
        let server = AuditServer(folders: [remote]), store = LibraryStore(fileURL: file)
        await store.sync(token: "a", client: server)
        let folder = try #require(store.collections.first?.id)
        await server.replace(folderID: 8, posts: [try auditPost(6)])
        await server.configure(holdSnapshot: true)
        let syncing = Task { await store.sync(token: "a", client: server) }
        await server.waitUntilHeld()
        try store.save(auditPost(5), to: [folder])
        await server.release(); await syncing.value
        #expect(Set(store.posts(in: folder).map(\.id)) == [5,6])
        #expect(store.pendingCount == 1)
    }

    @Test func metadataOmissionDoesNotDeleteKnownCollectionMembership() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let post = try auditPost(7), remote = RemoteCollection(id: 9, name: "Cloud", userId: 1)
        let server = AuditServer(folders: [remote], items: [9: [post]]), store = LibraryStore(fileURL: file)
        await store.sync(token: "a", client: server)
        await server.replace(folderID: 9, posts: [], ids: [7])
        await store.sync(token: "a", client: server)
        #expect(store.contains(post)); #expect(store.posts(in: nil) == [post])
    }

    @Test func deletedCloudFolderWithPendingEditsIsRecoverableWithoutBlockingSync() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = AuditServer(folders: [RemoteCollection(id: 9, name: "Cloud", userId: 1)], items: [9: [try auditPost(8)]]), store = LibraryStore(fileURL: file)
        await store.sync(token: "a", client: original)
        let folder = try #require(store.collections.first?.id)
        try store.save(auditPost(9), to: [folder])
        let deleted = AuditServer()
        await store.sync(token: "a", client: deleted)
        #expect(store.collections.first?.isLocalRecovery == true)
        #expect(Set(store.posts(in: folder).map(\.id)) == [8,9])
        #expect(await deleted.writes == 0); #expect(await deleted.creates == 0)
        try store.resumeSync(collectionID: folder)
        await store.sync(token: "a", client: deleted)
        #expect(await deleted.creates == 1); #expect(store.pendingCount == 0)
        #expect(store.collections.first?.isLocalRecovery == false)
    }

    @Test func namesRespectServerUTF16LimitAndCorruptedFolderIDsAreProtected() throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: file)
        #expect(throws: (any Error).self) { try store.createCollection(name: String(repeating: "🧑‍💻", count: 10)) }
        #expect(store.collections.isEmpty)
        _ = try store.createCollection(name: String(repeating: "字", count: 30))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let folders = try #require(object["collections"] as? [[String: Any]])
        object["collections"] = folders + folders
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        try corrupted.write(to: file)
        let loaded = LibraryStore(fileURL: file)
        #expect(loaded.errorMessage != nil)
        #expect(throws: (any Error).self) { try loaded.toggle(auditPost(1)) }
        #expect(try Data(contentsOf: file) == corrupted)
    }

    @Test func contestsAreNeverTreatedAsBookmarkFolders() async throws {
        let file = file(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let server = AuditServer(folders: [RemoteCollection(id: 12, name: "Contest", userId: 1, mode: "Contest")], items: [12: [try auditPost(12)]]), store = LibraryStore(fileURL: file)
        await store.sync(token: "fixture", client: server)
        #expect(store.availableCollections.isEmpty)
        #expect(await server.writes == 0); #expect(await server.creates == 0)
    }
}

struct RatingAndDownloadAuditTests {
    @Test func conflictingRatingsUseTheMoreRestrictiveSignalAndBlockedNeverLeaks() throws {
        let json = #"{"id":1,"url":"https://image.civitai.com/test.jpg","browsingLevel":1,"nsfwLevel":4,"nsfw":false}"#
        let post = try JSONDecoder().decode(MediaPost.self, from: Data(json.utf8))
        #expect(post.contentRating == .r); #expect(!post.isAllowed(ratings: 1))
        #expect(ContentRating.classify(browsingLevel: 1, nsfwLevel: .number(32), legacyNsfw: .bool(false)) == nil)
    }

    @Test func downloadedRatingSurvivesRenegotiatedExtensionsAndOldHistoryMigration() throws {
        let plan = try DownloadPlan.media(auditPost(10, rating: 16))
        #expect(plan.contentRating(for: "civitai-10.webp") == .xxx)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var assets = try #require(object["assets"] as? [[String: Any]])
        for index in assets.indices { assets[index].removeValue(forKey: "rating") }
        object["assets"] = assets
        let legacy = try JSONDecoder().decode(DownloadPlan.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.contentRating(for: "civitai-10.png") == .xxx)
        #expect(legacy.contentRating(for: "civitai-10.civitai.info") == nil)
    }

    @Test func modelPreviewUsesSelectedRatingInsteadOfAlwaysForcingPG() throws {
        let data = Data(#"{"id":99,"name":"v1","files":[{"id":1,"name":"model.safetensors","type":"Model","downloadUrl":"https://civitai.com/api/download/models/99"}],"images":[{"url":"https://image.civitai.com/r.jpg","type":"image","nsfwLevel":4,"nsfw":true}]}"#.utf8)
        let document = try ModelVersionDocument(data: data)
        var options = DownloadOptions(); options.ratings = 4
        let plan = try DownloadPlan.model(document, file: #require(document.version.files.first), options: options)
        #expect(plan.assets.contains { $0.kind == .image && $0.rating == .r })
        options.ratings = 1
        let restricted = try DownloadPlan.model(document, file: #require(document.version.files.first), options: options)
        #expect(!restricted.assets.contains { $0.kind == .image })
    }
}

private actor RatingFeedServer: FeedServing {
    var requests = 0
    func fetch(query: FeedQuery, cursor: String?, token: String?) async throws -> FeedPage {
        requests += 1
        switch cursor {
        case nil: return FeedPage(items: [try auditPost(1)], cursor: "a")
        case "a": return FeedPage(items: [try auditPost(2, rating: 4)], cursor: "b")
        default: return FeedPage(items: [try auditPost(3)])
        }
    }
}
@MainActor struct FeedAuditTests {
    @Test func noSelectedRatingMakesNoNetworkRequest() async {
        let server = RatingFeedServer()
        var query = FeedQuery(); query.ratings = 0
        let checked = FeedStore(client: server)
        await checked.refresh(query: query)
        #expect(await server.requests == 0); #expect(checked.posts.isEmpty); #expect(!checked.hasMore)
    }
    @Test func filteredPaginationCanContinueWithoutRepeatingTheSameFocusedPost() async throws {
        let server = RatingFeedServer(), store = FeedStore(client: server)
        await store.refresh(query: FeedQuery())
        let first = try #require(store.posts.first)
        await store.loadMoreIfNeeded(after: first)
        #expect(store.posts.map(\.id) == [1,3]); #expect(await server.requests == 3)
    }
}

private final class PartialCollectionMetadataProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        if request.url!.path == "/api/v1/images" {
            body = #"{"items":[{"id":1,"url":"https://image.civitai.com/1.jpg","browsingLevel":1},{"id":999,"url":"https://image.civitai.com/999.jpg","browsingLevel":1}]}"#
        } else {
            body = #"{"result":{"data":{"json":{"collectionItems":[{"type":"image","data":{"id":1}},{"type":"image","data":{"id":2}}]}}}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct CollectionSnapshotTransportAuditTests {
    @Test func hydrationOmissionsPreserveIDsAndUnrequestedMetadataIsIgnored() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PartialCollectionMetadataProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let snapshot = try await CollectionClient(session: session).snapshot(in: 9, token: "fixture")
        #expect(snapshot.ids == [1,2]); #expect(snapshot.posts.map(\.id) == [1])
    }
}
