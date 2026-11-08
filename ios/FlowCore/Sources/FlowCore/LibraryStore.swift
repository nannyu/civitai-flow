import Foundation
import Observation

public struct BookmarkCollection: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var remoteID: Int?
    public var ownerID: Int?
    public var type: String?
    public var postIDs: Set<Int>
    public var syncPaused: Bool? = nil
    public var supportsMedia: Bool { type == nil || type == "Image" }
    public var isLocalRecovery: Bool { syncPaused == true }
    public var webURL: URL? { remoteID.flatMap { URL(string: "https://civitai.red/collections/\($0)") } }
}

@MainActor @Observable
public final class LibraryStore {
    public private(set) var posts: [MediaPost] = []
    public private(set) var collections: [BookmarkCollection] = []
    public private(set) var errorMessage: String?
    public private(set) var syncError: String?
    public private(set) var isSyncing = false
    public private(set) var account: CollectionAccount?
    public private(set) var lastSyncedAt: Date?
    public var pendingCount: Int {
        let activeIDs = Set(availableCollections.map(\.id))
        return changes.filter { activeIDs.contains($0.collectionID) }.count
    }
    public var availableCollections: [BookmarkCollection] {
        collections.filter { $0.ownerID == nil || $0.ownerID == account?.id }
    }
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var changes: [Change] = []
    @ObservationIgnored private var syncGeneration = 0

    private struct Change: Codable, Sendable {
        let id: UUID
        let collectionID: String
        let postID: Int
        let included: Bool
    }
    private struct Snapshot: Codable {
        var posts: [MediaPost]
        var collections: [BookmarkCollection]
        var changes: [Change]
        var account: CollectionAccount?
        var lastSyncedAt: Date?
    }
    private var snapshot: Snapshot {
        Snapshot(posts: posts, collections: collections, changes: changes, account: account, lastSyncedAt: lastSyncedAt)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            if let old = try? JSONDecoder().decode([MediaPost].self, from: data) {
                var seen = Set<Int>()
                posts = old.filter { seen.insert($0.id).inserted }
                if !posts.isEmpty {
                    let folder = BookmarkCollection(id: UUID().uuidString, name: "默认收藏", type: "Image", postIDs: Set(posts.map(\.id)))
                    collections = [folder]
                    changes = posts.map { Change(id: UUID(), collectionID: folder.id, postID: $0.id, included: true) }
                }
            } else {
                let saved = try JSONDecoder().decode(Snapshot.self, from: data)
                let folderIDs = Set(saved.collections.map(\.id))
                guard folderIDs.count == saved.collections.count,
                      Set(saved.posts.map(\.id)).count == saved.posts.count,
                      saved.collections.allSatisfy({ !$0.id.isEmpty && ($0.ownerID ?? 1) > 0 && ($0.remoteID ?? 1) > 0 }),
                      saved.changes.allSatisfy({ folderIDs.contains($0.collectionID) && $0.postID > 0 }) else { throw LibraryError.unreadable }
                posts = saved.posts; collections = saved.collections; changes = saved.changes
                account = saved.account; lastSyncedAt = saved.lastSyncedAt
                // Older versions did not bind an offline-created folder until its first upload.
                if let owner = account?.id {
                    for index in collections.indices where collections[index].remoteID == nil && collections[index].ownerID == nil {
                        collections[index].ownerID = owner
                    }
                }
            }
        } catch {
            loadFailed = true
            errorMessage = "收藏文件读取失败，原文件已保留。请先备份或恢复文件，再重新打开应用。"
        }
    }

    public func contains(_ post: MediaPost) -> Bool { !collectionIDs(for: post).isEmpty }
    public func collectionIDs(for post: MediaPost) -> Set<String> {
        Set(availableCollections.filter { $0.postIDs.contains(post.id) }.map(\.id))
    }
    public func posts(in collectionID: String? = nil) -> [MediaPost] {
        let folders = availableCollections.filter { collectionID == nil || $0.id == collectionID }
        let ids = folders.reduce(into: Set<Int>()) { $0.formUnion($1.postIDs) }
        return posts.filter { ids.contains($0.id) }
    }

    @discardableResult public func createCollection(name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 30 else { throw LibraryError.invalidName }
        let folder = BookmarkCollection(id: UUID().uuidString, name: name, ownerID: account?.id, type: "Image", postIDs: [])
        try commit(posts: posts, collections: collections + [folder], changes: changes)
        return folder.id
    }

    /// A picker can provide its initial selection to preserve memberships imported while it was open.
    public func save(_ post: MediaPost, to selected: Set<String>, replacing baseline: Set<String>? = nil) throws {
        let allowed = Set(availableCollections.filter(\.supportsMedia).map(\.id))
        guard selected.isSubset(of: allowed) else { throw LibraryError.invalidCollection }
        let desired: Set<String>
        if let baseline {
            desired = collectionIDs(for: post).subtracting(baseline.subtracting(selected)).union(selected.subtracting(baseline))
        } else { desired = selected }
        var folders = collections, pending = changes
        for index in folders.indices where allowed.contains(folders[index].id) {
            let id = folders[index].id, included = desired.contains(id)
            guard folders[index].postIDs.contains(post.id) != included else { continue }
            if included { folders[index].postIDs.insert(post.id) } else { folders[index].postIDs.remove(post.id) }
            pending.removeAll { $0.collectionID == id && $0.postID == post.id }
            if !folders[index].isLocalRecovery {
                pending.append(Change(id: UUID(), collectionID: id, postID: post.id, included: included))
            }
        }
        var updated = posts.filter { $0.id != post.id }
        if folders.contains(where: { $0.postIDs.contains(post.id) }) { updated.insert(post, at: 0) }
        try commit(posts: updated, collections: folders, changes: pending)
    }

    public func toggle(_ post: MediaPost) throws {
        if contains(post) { try save(post, to: []) }
        else {
            let id = try availableCollections.first(where: \.supportsMedia)?.id ?? createCollection(name: "默认收藏")
            try save(post, to: [id])
        }
    }

    public func resumeSync(collectionID: String) throws {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }),
              availableCollections.contains(where: { $0.id == collectionID }) else { throw LibraryError.invalidCollection }
        var updated = collections
        updated[index].syncPaused = false
        var pending = changes.filter { $0.collectionID != collectionID }
        pending += updated[index].postIDs.map { Change(id: UUID(), collectionID: collectionID, postID: $0, included: true) }
        try commit(posts: posts, collections: updated, changes: pending)
    }

    public func disconnect() {
        syncGeneration += 1
        syncError = nil
        // Keep the last account's offline library scoped to that account after removing its key.
        var updated = snapshot
        updated.lastSyncedAt = nil
        do { try apply(updated) } catch { errorMessage = error.localizedDescription }
    }

    public func sync(token: String, client: any CollectionServing = CollectionClient()) async {
        guard !token.isEmpty, !loadFailed else { return }
        let generation = syncGeneration
        while isSyncing {
            do { try await Task.sleep(for: .milliseconds(100)); try checkSync(generation) }
            catch { return }
        }
        guard !Task.isCancelled, generation == syncGeneration else { return }
        isSyncing = true; syncError = nil
        defer { isSyncing = false }
        do {
            let user = try await client.account(token: token)
            try checkSync(generation)
            guard user.id > 0 else { throw CivitaiError.invalidResponse }
            var authenticated = snapshot
            if account?.id != user.id { authenticated.lastSyncedAt = nil }
            authenticated.account = user
            for index in authenticated.collections.indices where authenticated.collections[index].ownerID == nil {
                authenticated.collections[index].ownerID = user.id
            }
            try apply(authenticated)
            // Contest collection writes are submissions and can carry entry fees, not ordinary bookmarks.
            var remote = try await client.collections(token: token).filter { $0.userId == user.id && $0.mode != "Contest" }
            try checkSync(generation)
            guard remote.allSatisfy({ $0.id > 0 }), Set(remote.map(\.id)).count == remote.count else { throw CivitaiError.invalidResponse }
            try reconcileDeletedFolders(remoteIDs: Set(remote.map(\.id)), ownerID: user.id)
            for local in collections.filter({ $0.remoteID == nil && !$0.isLocalRecovery && $0.supportsMedia && ($0.ownerID == nil || $0.ownerID == user.id) }) {
                try checkSync(generation)
                let created = try await client.create(name: local.name, token: token)
                try checkSync(generation)
                guard created.userId == user.id, created.id > 0 else { throw CivitaiError.invalidResponse }
                if let index = collections.firstIndex(where: { $0.id == local.id }) {
                    var updated = collections
                    updated[index].remoteID = created.id; updated[index].ownerID = user.id
                    try commit(posts: posts, collections: updated, changes: changes)
                }
                remote.append(created)
            }
            let queued = changes
            var sent = Set<UUID>()
            for change in queued {
                try checkSync(generation)
                guard changes.contains(where: { $0.id == change.id }),
                      let folder = collections.first(where: { $0.id == change.collectionID }), !folder.isLocalRecovery,
                      folder.ownerID == user.id, let remoteID = folder.remoteID else { continue }
                try await client.save(postID: change.postID, collectionID: remoteID, included: change.included, token: token)
                try checkSync(generation)
                sent.insert(change.id)
            }
            for folder in remote {
                try checkSync(generation)
                let incoming = folder.supportsMedia ? try await client.snapshot(in: folder.id, token: token) : CollectionMediaSnapshot(posts: [])
                try checkSync(generation)
                var updated = collections
                let index = updated.firstIndex { $0.remoteID == folder.id && $0.ownerID == user.id }
                let localID = index.map { updated[$0].id } ?? UUID().uuidString
                let pending = changes.filter { $0.collectionID == localID }
                var ids = incoming.ids
                for change in pending {
                    if change.included { ids.insert(change.postID) } else { ids.remove(change.postID) }
                }
                let merged = BookmarkCollection(id: localID, name: folder.name, remoteID: folder.id, ownerID: user.id, type: folder.type, postIDs: ids)
                if let index { updated[index] = merged } else { updated.append(merged) }
                var byID = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for post in incoming.posts where incoming.ids.contains(post.id) { byID[post.id] = post }
                let referenced = updated.reduce(into: Set<Int>()) { $0.formUnion($1.postIDs) }
                // A mutation response can precede replication into the read API. Keep its journal entry until read-back agrees.
                let confirmed = Set(pending.filter { sent.contains($0.id) && incoming.ids.contains($0.postID) == $0.included }.map(\.id))
                try commit(posts: byID.values.filter { referenced.contains($0.id) }.sorted { $0.id > $1.id }, collections: updated,
                           changes: changes.filter { !confirmed.contains($0.id) })
            }
            var completed = snapshot
            completed.lastSyncedAt = Date()
            try apply(completed)
            if availableCollections.contains(where: \.isLocalRecovery) {
                syncError = "网站已删除部分收藏夹，其中的本机修改已保留。可从收藏夹菜单选择重新同步。"
            }
        } catch {
            if !Task.isCancelled, generation == syncGeneration {
                syncError = "收藏同步未完成：\(error.localizedDescription) 本机修改已保留，可稍后重试。"
            }
        }
    }

    private func reconcileDeletedFolders(remoteIDs: Set<Int>, ownerID: Int) throws {
        var updated: [BookmarkCollection] = []
        var pending = changes
        for var folder in collections {
            if folder.ownerID == ownerID, let id = folder.remoteID, !remoteIDs.contains(id) {
                if changes.contains(where: { $0.collectionID == folder.id && $0.included }) {
                    folder.remoteID = nil; folder.syncPaused = true
                    updated.append(folder)
                }
                pending.removeAll { $0.collectionID == folder.id }
            } else { updated.append(folder) }
        }
        let referenced = updated.reduce(into: Set<Int>()) { $0.formUnion($1.postIDs) }
        try commit(posts: posts.filter { referenced.contains($0.id) }, collections: updated, changes: pending)
    }
    private func checkSync(_ generation: Int) throws {
        try Task.checkCancellation()
        if generation != syncGeneration { throw CancellationError() }
    }
    private func commit(posts updatedPosts: [MediaPost], collections updatedCollections: [BookmarkCollection], changes updatedChanges: [Change]) throws {
        var updated = snapshot
        updated.posts = updatedPosts; updated.collections = updatedCollections; updated.changes = updatedChanges
        try apply(updated)
    }
    private func apply(_ updated: Snapshot) throws {
        guard !loadFailed else { throw LibraryError.unreadable }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            posts = updated.posts; collections = updated.collections; changes = updated.changes
            account = updated.account; lastSyncedAt = updated.lastSyncedAt; errorMessage = nil
        } catch { errorMessage = "收藏保存失败，请检查设备的可用空间。"; throw error }
    }
    public enum LibraryError: LocalizedError {
        case unreadable, invalidName, invalidCollection
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "收藏文件无法读取，已停止写入以保护现有收藏。"
            case .invalidName: return "请输入 1–30 个字符的收藏夹名称。"
            case .invalidCollection: return "收藏夹已变更，请重新选择。"
            }
        }
    }
}
