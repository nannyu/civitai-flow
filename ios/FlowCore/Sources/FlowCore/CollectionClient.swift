import Foundation

public struct CollectionAccount: Codable, Sendable {
    public let id: Int
    public let username: String
    public init(id: Int, username: String) { self.id = id; self.username = username }
}

public struct RemoteCollection: Codable, Sendable {
    public let id: Int
    public let name: String
    public let type: String?
    public let userId: Int
    public let mode: String?
    public init(id: Int, name: String, type: String? = "Image", userId: Int, mode: String? = nil) {
        self.id = id; self.name = name; self.type = type; self.userId = userId; self.mode = mode
    }
    public var supportsMedia: Bool { type == nil || type == "Image" }
}

public struct CollectionMediaSnapshot: Sendable {
    public let ids: Set<Int>
    public let posts: [MediaPost]
    public init(ids: Set<Int>, posts: [MediaPost]) { self.ids = ids; self.posts = posts }
    public init(posts: [MediaPost]) { self.init(ids: Set(posts.map(\.id)), posts: posts) }
}

public protocol CollectionServing: Sendable {
    func account(token: String) async throws -> CollectionAccount
    func collections(token: String) async throws -> [RemoteCollection]
    func create(name: String, token: String) async throws -> RemoteCollection
    func save(postID: Int, collectionID: Int, included: Bool, token: String) async throws
    func media(in collectionID: Int, token: String) async throws -> [MediaPost]
    func snapshot(in collectionID: Int, token: String) async throws -> CollectionMediaSnapshot
}

public extension CollectionServing {
    func snapshot(in collectionID: Int, token: String) async throws -> CollectionMediaSnapshot {
        try await CollectionMediaSnapshot(posts: media(in: collectionID, token: token))
    }
}

/// Civitai's collection procedures use the site's superjson tRPC envelope.
public struct CollectionClient: CollectionServing {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func account(token: String) async throws -> CollectionAccount {
        let data = try await send(URLRequest(url: URL(string: "https://civitai.red/api/v1/me")!), token: token)
        return try JSONDecoder().decode(CollectionAccount.self, from: data)
    }
    public func collections(token: String) async throws -> [RemoteCollection] {
        let data = try await rpc("collection.getAllUser", input: ["contributingOnly": true], token: token)
        return try JSONDecoder().decode([RemoteCollection].self, from: data)
    }
    public func create(name: String, token: String) async throws -> RemoteCollection {
        let data = try await rpc("collection.upsert", input: ["name": name, "type": "Image", "read": "Private", "write": "Private"], mutation: true, token: token)
        return try JSONDecoder().decode(RemoteCollection.self, from: data)
    }
    public func save(postID: Int, collectionID: Int, included: Bool, token: String) async throws {
        let input: [String: Any] = ["type": "Image", "imageId": postID,
                                    "collections": included ? [["collectionId": collectionID]] : [],
                                    "removeFromCollectionIds": included ? [] : [collectionID]]
        _ = try await rpc("collection.saveItem", input: input, mutation: true, token: token)
    }
    public func media(in collectionID: Int, token: String) async throws -> [MediaPost] {
        try await snapshot(in: collectionID, token: token).posts
    }
    public func snapshot(in collectionID: Int, token: String) async throws -> CollectionMediaSnapshot {
        var cursor: String?, visited = Set<String>(), ids = Set<Int>()
        repeat {
            var input: [String: Any] = ["collectionId": collectionID, "limit": 100, "browsingLevel": 31]
            if let cursor { input["cursor"] = cursor }
            let data = try await rpc("collection.getAllCollectionItems", input: input, token: token)
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = page["collectionItems"] as? [[String: Any]] else { throw CivitaiError.invalidResponse }
            for entry in entries where entry["type"] as? String == "image" {
                if let image = entry["data"] as? [String: Any], let id = image["id"] as? Int { ids.insert(id) }
            }
            if let value = page["nextCursor"] as? String { cursor = value }
            else if let value = page["nextCursor"] as? Int { cursor = String(value) }
            else { cursor = nil }
            if let cursor, !cursor.isEmpty {
                guard visited.insert(cursor).inserted else { throw CivitaiError.invalidResponse }
            } else { break }
            try Task.checkCancellation()
        } while true
        // Hydrate through the public API: collection entries carry raw CDN IDs and omit generation metadata.
        let sorted = ids.sorted()
        var posts: [MediaPost] = []
        for start in stride(from: 0, to: sorted.count, by: 100) {
            var parts = URLComponents(string: "https://civitai.red/api/v1/images")!
            parts.queryItems = [URLQueryItem(name: "ids", value: sorted[start..<min(start + 100, sorted.count)].map(String.init).joined(separator: ",")),
                                URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "browsingLevel", value: "31"),
                                URLQueryItem(name: "withMeta", value: "true")]
            let data = try await send(URLRequest(url: parts.url!), token: token)
            posts += try JSONDecoder().decode(FeedPage.self, from: data).items.filter { ids.contains($0.id) && $0.isSupportedMedia }
        }
        return CollectionMediaSnapshot(ids: ids, posts: posts)
    }

    private func rpc(_ procedure: String, input: [String: Any], mutation: Bool = false, token: String) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["json": input], options: [.sortedKeys])
        var parts = URLComponents(string: "https://civitai.red/api/trpc/\(procedure)")!
        if !mutation { parts.queryItems = [URLQueryItem(name: "input", value: String(decoding: body, as: UTF8.self))] }
        var request = URLRequest(url: parts.url!)
        if mutation { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data = try await send(request, token: token)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = envelope["result"] as? [String: Any], let value = result["data"] as? [String: Any],
              let json = value["json"] else { throw CivitaiError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
    }
    private func send(_ original: URLRequest, token: String) async throws -> Data {
        var request = original
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: CollectionRedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw CivitaiError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw CivitaiError.authentication
        case 429: throw CivitaiError.rateLimited
        default: throw CivitaiError.http(http.statusCode)
        }
    }
}

private final class CollectionRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "civitai.red", request.url?.user == nil,
              request.url?.password == nil, request.url?.port == nil || request.url?.port == 443 else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
