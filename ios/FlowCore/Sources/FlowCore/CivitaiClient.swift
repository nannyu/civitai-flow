import Foundation

public enum FeedSort: String, CaseIterable, Sendable {
    case mostReactions = "Most Reactions", newest = "Newest", mostComments = "Most Comments"
    public var title: String {
        switch self { case .mostReactions: return "热门"; case .newest: return "最新"; case .mostComments: return "热议" }
    }
}

public enum FeedPeriod: String, CaseIterable, Sendable {
    case day = "Day", week = "Week", month = "Month", allTime = "AllTime"
    public var title: String {
        switch self { case .day: return "今天"; case .week: return "本周"; case .month: return "本月"; case .allTime: return "全部时间" }
    }
}

public enum MediaFilter: String, CaseIterable, Sendable {
    case all = "", image, video
    public var title: String {
        switch self { case .all: return "全部"; case .image: return "图片"; case .video: return "视频" }
    }
}

public struct FeedQuery: Hashable, Sendable {
    public var sort: FeedSort = .mostReactions
    public var period: FeedPeriod = .week
    public var media: MediaFilter = .all
    public var username: String = ""
    public var ratings: Int = ContentRating.pg.rawValue
    public init() {}
}

public enum CivitaiError: LocalizedError, Equatable {
    case invalidResponse, authentication, rateLimited, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法读取的数据，请稍后重试。"
        case .authentication: return "访问被拒绝，请检查 API Key 或所在网络的访问权限。"
        case .rateLimited: return "请求太频繁，请稍等片刻再试。"
        case .http(let code): return "Civitai 暂时不可用（\(code)），请稍后重试。"
        }
    }
}

public protocol FeedServing: Sendable {
    func fetch(query: FeedQuery, cursor: String?, token: String?) async throws -> FeedPage
}

public struct CivitaiClient: FeedServing {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func request(query: FeedQuery, cursor: String?, token: String?) -> URLRequest {
        var components = URLComponents(string: "https://civitai.com/api/v1/images")!
        var items = [
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "browsingLevel", value: String(query.ratings & ContentRating.allMask)),
            URLQueryItem(name: "withMeta", value: "true"),
            URLQueryItem(name: "sort", value: query.sort.rawValue),
            URLQueryItem(name: "period", value: query.period.rawValue)
        ]
        if query.media != .all { items.append(URLQueryItem(name: "type", value: query.media.rawValue)) }
        let username = query.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty { items.append(URLQueryItem(name: "username", value: username)) }
        // Reconstruct against a fixed origin; never send a credential to a returned nextPage URL.
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func fetch(query: FeedQuery, cursor: String?, token: String?) async throws -> FeedPage {
        let (data, response) = try await session.data(for: request(query: query, cursor: cursor, token: token), delegate: DownloadRedirectDelegate())
        guard let http = response as? HTTPURLResponse else { throw CivitaiError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw CivitaiError.authentication
        case 429: throw CivitaiError.rateLimited
        default: throw CivitaiError.http(http.statusCode)
        }
        do { return try JSONDecoder().decode(FeedPage.self, from: data) }
        catch { throw CivitaiError.invalidResponse }
    }
}
