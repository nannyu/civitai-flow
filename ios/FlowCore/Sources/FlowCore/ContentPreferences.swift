import Foundation

public enum ContentRating: Int, CaseIterable, Codable, Sendable {
    case pg = 1, pg13 = 2, r = 4, x = 8, xxx = 16
    public var title: String {
        switch self { case .pg: return "PG"; case .pg13: return "PG-13"; case .r: return "R"; case .x: return "X"; case .xxx: return "XXX" }
    }
    public var isMature: Bool { rawValue >= 4 }
    public static let allMask = 31

    public static func classify(browsingLevel: Int? = nil, nsfwLevel: JSONValue? = nil, legacyNsfw: JSONValue? = nil) -> ContentRating? {
        func decode(_ text: String) -> ContentRating? {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "none", "false", "0", "pg": return .pg
            case "soft", "pg13", "pg-13": return .pg13
            case "mature", "r": return .r
            case "x": return .x
            case "xxx": return .xxx
            default: return Int(text).flatMap(ContentRating.init(rawValue:))
            }
        }
        var levels: [ContentRating] = []
        if let browsingLevel {
            guard let rating = ContentRating(rawValue: browsingLevel) else { return nil }
            levels.append(rating)
        }
        if let nsfwLevel, nsfwLevel != .null {
            guard let rating = decode(nsfwLevel.text) else { return nil }
            levels.append(rating)
        }
        if let legacyNsfw, let legacy = decode(legacyNsfw.text) { levels.append(legacy) }
        guard let rating = levels.max(by: { $0.rawValue < $1.rawValue }) else { return nil }
        if legacyNsfw?.text.lowercased() == "true", rating == .pg { return nil }
        return rating
    }
}

public enum DiscoverSection: String, CaseIterable, Sendable {
    case home, models, images, videos, models3d, hubs, articles, comics, crucibles, updates, shop
    public var title: String {
        switch self { case .models3d: return "3D Models"; default: return rawValue }
    }
    public var isNative: Bool { self == .home || self == .images || self == .videos }
    public var media: MediaFilter { self == .images ? .image : (self == .videos ? .video : .all) }
    public var url: URL {
        // The site's 3D navigation is /3d-models.
        URL(string: "https://civitai.red/" + (self == .home ? "" : (self == .models3d ? "3d-models" : rawValue)))!
    }
}

public enum SearchTarget: String, CaseIterable, Sendable {
    case models, images, articles, users, collections, comics, bounties, tools
    public var title: String { rawValue }
    public func url(query: String) -> URL {
        var parts = URLComponents(string: "https://civitai.red/search/\(rawValue)")!
        parts.queryItems = [URLQueryItem(name: "query", value: query.trimmingCharacters(in: .whitespacesAndNewlines))]
        return parts.url!
    }
}
