import Foundation

public enum DownloadError: LocalizedError, Equatable {
    case invalidLink, noFiles, unsafeURL, invalidFile, missingFiles
    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "请输入 Civitai 模型页面或模型下载链接。"
        case .noFiles: return "该版本没有可下载的模型文件。"
        case .unsafeURL: return "下载地址无效，或不是安全的 HTTPS 地址。"
        case .invalidFile: return "服务器没有返回有效文件，可能需要 API Key 或下载权限。"
        case .missingFiles: return "下载文件已被移除，请重新下载。"
        }
    }
}

public struct ModelLink: Equatable, Sendable {
    public let modelID: Int?
    public let versionID: Int?
    public let fileQuery: [String: String]

    public init(_ text: String) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", ["civitai.com", "www.civitai.com", "civitai.green", "civitai.red"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw DownloadError.invalidLink }
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func positive(_ value: String?) -> Int? { value.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } }
        var selection: [String: String] = [:]
        for item in query where ["type", "format", "size", "fp"].contains(item.name) { selection[item.name] = item.value }
        fileQuery = selection
        if parts.count >= 2, parts[0] == "models", let id = positive(parts[1]) {
            modelID = id
            if let version = query.first(where: { $0.name == "modelVersionId" }) {
                guard let id = positive(version.value) else { throw DownloadError.invalidLink }
                versionID = id
            } else { versionID = nil }
        } else if parts.count == 4, Array(parts.prefix(3)) == ["api", "download", "models"], let id = positive(parts[3]) {
            modelID = nil
            versionID = id
        } else { throw DownloadError.invalidLink }
    }
}

public struct ModelFile: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let type: String
    public let sizeKB: Double?
    public let primary: Bool?
    public let downloadUrl: URL
    public let metadata: [String: JSONValue]?

    public func matches(_ query: [String: String]) -> Bool {
        let items = URLComponents(url: downloadUrl, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.allSatisfy { key, value in items.contains { $0.name == key && $0.value == value } }
    }
}

public struct ModelVersion: Decodable, Identifiable, Sendable {
    public let id: Int
    public let modelId: Int?
    public let name: String
    public let description: String?
    public let baseModel: String?
    public let files: [ModelFile]
    public let images: [Preview]?
    public let model: ModelInfo?

    public struct ModelInfo: Decodable, Sendable { public let name: String }
    public struct Preview: Decodable, Sendable {
        public let url: URL
        public let type: String?
        public let width: Int?
        public let nsfw: JSONValue?
        public let nsfwLevel: Int?
        public var isVideo: Bool { type == "video" || ["mp4", "webm", "mov"].contains(url.pathExtension.lowercased()) }
        public var isSafeForWork: Bool {
            contentRating == .pg
        }
        public var contentRating: ContentRating? {
            ContentRating.classify(nsfwLevel: nsfwLevel.map { .number(Double($0)) }, legacyNsfw: nsfw)
        }
        public func isAllowed(ratings: Int) -> Bool { contentRating.map { ratings & $0.rawValue != 0 } ?? false }
    }
    public var downloadableFiles: [ModelFile] { files.filter { $0.type != "Training Data" } }
}

public struct ModelCatalog: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let description: String?
    public let modelVersions: [Version]
    public struct Version: Decodable, Identifiable, Sendable {
        public let id: Int
        public let name: String
    }
}

public struct ModelVersionDocument: Sendable {
    public let version: ModelVersion
    /// Retain all API fields for .civitai.info, including fields this client does not understand.
    public let json: Data
    public init(data: Data) throws {
        version = try JSONDecoder().decode(ModelVersion.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data)
        json = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

public struct ModelClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func catalog(id: Int, token: String?) async throws -> ModelCatalog {
        let data = try await data(path: "models/\(id)", token: token)
        do {
            let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
            guard catalog.id == id else { throw CivitaiError.invalidResponse }
            return catalog
        }
        catch { throw CivitaiError.invalidResponse }
    }

    public func version(id: Int, token: String?) async throws -> ModelVersionDocument {
        let data = try await data(path: "model-versions/\(id)", token: token)
        do {
            let document = try ModelVersionDocument(data: data)
            guard document.version.id == id else { throw CivitaiError.invalidResponse }
            return document
        }
        catch { throw CivitaiError.invalidResponse }
    }

    private func data(path: String, token: String?) async throws -> Data {
        let request = try DownloadHTTP.request(url: URL(string: "https://civitai.com/api/v1/\(path)")!, token: token)
        let (data, response) = try await session.data(for: request, delegate: DownloadRedirectDelegate())
        try DownloadHTTP.validate(response)
        return data
    }
}
