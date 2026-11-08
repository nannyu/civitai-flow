import Foundation

/// Civitai generation metadata contains strings, numbers, arrays and nested objects.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.formatted(.number.grouping(.never))
        case .bool(let value): return value ? "true" : "false"
        case .object, .array:
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        case .null: return ""
        }
    }
}

public struct MediaPost: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let url: URL
    public let width: Int?
    public let height: Int?
    public let type: String?
    public let nsfw: Bool?
    public let nsfwLevel: JSONValue?
    public let browsingLevel: Int?
    public let username: String?
    public let baseModel: String?
    public let postId: Int?
    public let thumbnail: Thumbnail?
    public let stats: Stats?
    public let meta: [String: JSONValue]?

    public struct Thumbnail: Codable, Hashable, Sendable {
        public let url: URL?
    }

    public struct Stats: Codable, Hashable, Sendable {
        public let likeCount: Int?
        public let heartCount: Int?
        public let commentCount: Int?
    }

    public var isVideo: Bool {
        type == "video" || ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased())
    }

    public var isSupportedMedia: Bool { type == nil || type == "image" || type == "video" }

    /// Fail closed when an item has no classification; never trust filtering alone.
    public var isSafeForWork: Bool {
        if nsfw == true { return false }
        if let browsingLevel { return browsingLevel == 1 }
        if let nsfwLevel {
            return ["none", "0", "1"].contains(nsfwLevel.text.lowercased())
        }
        return nsfw == false
    }

    public var creator: String { username ?? "未知创作者" }
    public var prompt: String? { nonemptyMetadata("prompt") }
    public var negativePrompt: String? { nonemptyMetadata("negativePrompt") }
    public var title: String { baseModel ?? (isVideo ? "动态灵感" : "视觉灵感") }
    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 0.75 }
        return Double(width) / Double(height)
    }
    public var webURL: URL { URL(string: "https://civitai.com/images/\(id)")! }

    public struct ModelResource: Identifiable, Sendable {
        public let id: Int
        public let name: String
        public var downloadURL: URL { URL(string: "https://civitai.com/api/download/models/\(id)")! }
    }

    public var modelResources: [ModelResource] {
        var seen: Set<Int> = []
        return ["civitaiResources", "resources"].flatMap { key -> [ModelResource] in
            guard case .array(let values) = meta?[key] else { return [] }
            return values.compactMap { value in
                guard case .object(let fields) = value,
                      let raw = (fields["modelVersionId"] ?? fields["versionId"])?.text,
                      let id = Int(raw), id > 0, seen.insert(id).inserted else { return nil }
                return ModelResource(id: id, name: fields["name"]?.text ?? "模型版本 \(id)")
            }
        }
    }

    public func nonemptyMetadata(_ key: String) -> String? {
        guard let text = meta?[key]?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    public var previewURL: URL? {
        if isVideo { return thumbnail?.url }
        // Only alter the documented Civitai image CDN transform segment.
        guard url.host == "image.civitai.com", url.path.contains("/original=true/") else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/original=true/", with: "/width=600/"))
    }
}

public struct FeedPage: Codable, Sendable {
    public let items: [MediaPost]
    public let metadata: Metadata?

    public struct Metadata: Codable, Sendable {
        public let nextCursor: String?
    }

    public init(items: [MediaPost], cursor: String? = nil) {
        self.items = items
        metadata = Metadata(nextCursor: cursor)
    }
}
