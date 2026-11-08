import Foundation

public struct DownloadOptions: Sendable {
    public var includePreview = true
    public var imagePreviewOnly = true
    public var includeDescription = true
    public var ratings = ContentRating.pg.rawValue
    public init() {}
}

public struct DownloadAsset: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case model, image, video }
    public let name: String
    public let url: URL?
    public let content: Data?
    public let kind: Kind?
    public let rating: ContentRating?

    public init(name: String, url: URL, kind: Kind, rating: ContentRating? = nil) {
        self.name = DownloadNaming.safe(name)
        self.url = url
        self.kind = kind
        self.rating = rating
        content = nil
    }
    public init(name: String, content: Data) {
        self.name = DownloadNaming.safe(name)
        self.content = content
        url = nil
        kind = nil
        rating = nil
    }
}

public struct DownloadPlan: Codable, Sendable {
    public let key: String
    public let title: String
    public let assets: [DownloadAsset]
    public let notes: [String]

    public init(key: String, title: String, assets: [DownloadAsset], notes: [String] = []) {
        self.key = key
        self.title = title
        self.assets = assets
        self.notes = notes
    }

    public static func model(_ document: ModelVersionDocument, file: ModelFile,
                             modelDescription: String? = nil, options: DownloadOptions = .init()) throws -> DownloadPlan {
        let version = document.version
        guard version.downloadableFiles.contains(file) else { throw DownloadError.noFiles }
        // Metadata file URLs must be canonical Civitai download endpoints, never arbitrary hosts with our API key.
        let url = try DownloadHTTP.modelURL(file.downloadUrl, versionID: version.id)
        let filename = DownloadNaming.safe(file.name)
        let stem = (filename as NSString).deletingPathExtension
        var assets = [DownloadAsset(name: filename, url: url, kind: .model),
                      DownloadAsset(name: "\(stem).civitai.info", content: document.json)]
        var notes: [String] = []
        if options.includePreview {
            if let preview = version.images?.first(where: {
                ($0.type == nil || $0.type == "image" || $0.type == "video") && $0.isAllowed(ratings: options.ratings) && (!options.imagePreviewOnly || !$0.isVideo)
            }) {
                let url = DownloadNaming.originalMediaURL(preview.url, isVideo: preview.isVideo)
                assets.append(DownloadAsset(name: "\(stem).preview.\(DownloadNaming.mediaExtension(url, isVideo: preview.isVideo))",
                                            url: url, kind: preview.isVideo ? .video : .image, rating: preview.contentRating))
            } else { notes.append("没有符合当前内容等级的预览文件，已跳过预览。") }
        }
        if options.includeDescription {
            let text = [modelDescription, version.description].compactMap { $0 }.map(DownloadNaming.plainText)
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !text.isEmpty { assets.append(DownloadAsset(name: "\(stem).description.txt", content: Data(text.utf8))) }
            else { notes.append("作者未提供描述，已跳过描述文件。") }
        }
        return DownloadPlan(key: "model-\(version.id)-\(file.id)", title: filename, assets: assets, notes: notes)
    }

    public static func media(_ post: MediaPost) throws -> DownloadPlan {
        let url = DownloadNaming.originalMediaURL(post.url, isVideo: post.isVideo)
        let stem = "civitai-\(post.id)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return DownloadPlan(key: "media-\(post.id)", title: "@\(post.creator) · \(post.id)", assets: [
            DownloadAsset(name: "\(stem).\(DownloadNaming.mediaExtension(url, isVideo: post.isVideo))", url: url, kind: post.isVideo ? .video : .image, rating: post.contentRating),
            DownloadAsset(name: "\(stem).civitai.info", content: try encoder.encode(post))
        ])
    }

    public func contentRating(for filename: String) -> ContentRating? {
        let stem = (filename as NSString).deletingPathExtension
        guard let asset = assets.first(where: { ($0.kind == .image || $0.kind == .video) && ($0.name as NSString).deletingPathExtension == stem }) else { return nil }
        if let rating = asset.rating { return rating }
        // Existing download histories predate explicit ratings; recover them from the bundled metadata.
        for metadata in assets where metadata.name.hasSuffix(".civitai.info") {
            guard let content = metadata.content else { continue }
            if let post = try? JSONDecoder().decode(MediaPost.self, from: content) { return post.contentRating }
            if let version = try? JSONDecoder().decode(ModelVersion.self, from: content),
               let preview = version.images?.first(where: { DownloadNaming.originalMediaURL($0.url, isVideo: $0.isVideo) == asset.url }) {
                return preview.contentRating
            }
        }
        return nil
    }
}

public enum DownloadNaming {
    public static func safe(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\0").union(.controlCharacters)
        var result = name.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if result.isEmpty { result = "download" }
        // Leave room for suffixes and avoid exceeding the filesystem's UTF-8 component limit.
        let ext = (result as NSString).pathExtension
        var stem = (result as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(String(ext.prefix(16)))"
        while (stem + suffix).utf8.count > 180 { stem.removeLast() }
        return stem + suffix
    }

    public static func originalMediaURL(_ url: URL, isVideo: Bool) -> URL {
        guard !isVideo, url.host == "image.civitai.com", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var segments = parts.path.components(separatedBy: "/")
        if let index = segments.firstIndex(where: { $0.hasPrefix("width=") || $0.hasPrefix("original=") }) {
            segments[index] = "original=true"
            parts.path = segments.joined(separator: "/")
        }
        return parts.url ?? url
    }

    public static func mediaExtension(_ url: URL, isVideo: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        let allowed = isVideo ? ["mp4", "mov", "webm"] : ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"]
        return allowed.contains(ext) ? ext : (isVideo ? "mp4" : "jpg")
    }

    public static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
