import Foundation

public enum DownloadHTTP {
    public static func isSecure(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    public static func request(url: URL, token: String?) throws -> URLRequest {
        guard isSecure(url) else { throw DownloadError.unsafeURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if isCredentialEndpoint(url), let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func isCredentialEndpoint(_ url: URL) -> Bool {
        url.host == "civitai.com" && (url.port == nil || url.port == 443) && url.path.hasPrefix("/api/")
    }

    public static func redirected(_ request: URLRequest, from original: URL?) -> URLRequest? {
        guard let url = request.url, isSecure(url) else { return nil }
        var redirected = request
        if original?.host != url.host || !isCredentialEndpoint(url) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return redirected
    }

    public static func modelURL(_ url: URL, versionID: Int) throws -> URL {
        guard isSecure(url), url.host == "civitai.com", url.port == nil || url.port == 443,
              url.path == "/api/download/models/\(versionID)" else { throw DownloadError.unsafeURL }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = parts.queryItems?.filter { ["type", "format", "size", "fp"].contains($0.name) }
        parts.fragment = nil
        return parts.url!
    }

    public static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CivitaiError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw CivitaiError.authentication
        case 429: throw CivitaiError.rateLimited
        default: throw CivitaiError.http(http.statusCode)
        }
    }
}

class DownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(DownloadHTTP.redirected(request, from: response.url))
    }
}

public struct DownloadProgress: Sendable {
    public let received: Int64
    public let expected: Int64
    public init(received: Int64, expected: Int64) { self.received = received; self.expected = expected }
    public var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

private final class FileDownloadDelegate: DownloadRedirectDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    init(progress: @escaping @Sendable (DownloadProgress) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let report = now.timeIntervalSince(lastUpdate) >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite
        if report { lastUpdate = now }
        lock.unlock()
        if report { progress(DownloadProgress(received: totalBytesWritten, expected: totalBytesExpectedToWrite)) }
    }
}

public protocol FileDownloading: Sendable {
    func download(_ asset: DownloadAsset, to directory: URL, token: String?,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> String
}

public struct FileDownloader: FileDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ asset: DownloadAsset, to directory: URL, token: String?,
                         progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> String {
        guard let url = asset.url, let kind = asset.kind else { throw DownloadError.unsafeURL }
        let request = try DownloadHTTP.request(url: url, token: token)
        let delegate = FileDownloadDelegate(progress: progress)
        // URLSession streams to a temporary file; a multi-GB checkpoint never becomes an in-memory Data.
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try DownloadHTTP.validate(response)
        let filename = try Self.validatedFilename(asset.name, kind: kind, response: response, file: temporary)
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(filename))
        return filename
    }

    public static func validatedFilename(_ name: String, kind: DownloadAsset.Kind, response: URLResponse, file: URL) throws -> String {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw DownloadError.invalidFile }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 512) ?? Data()
        let text = String(decoding: header, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.contains("html"), !mime.contains("json"), !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html") else {
            throw DownloadError.invalidFile
        }
        if let http = response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Content-Encoding") == nil, response.expectedContentLength > 0,
           Int64(size) != response.expectedContentLength { throw DownloadError.invalidFile }
        if kind == .model { return DownloadNaming.safe(name) }
        // Inspect bytes, since CDN format negotiation can differ from the URL's extension.
        let bytes = [UInt8](header)
        let ext: String
        if kind == .image {
            if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { ext = "png" }
            else if bytes.starts(with: [0xff, 0xd8, 0xff]) { ext = "jpg" }
            else if text.hasPrefix("gif87a") || text.hasPrefix("gif89a") { ext = "gif" }
            else if bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
                    String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" { ext = "webp" }
            else if bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp",
                    ["avif", "avis", "heic", "heix", "mif1"].contains(String(decoding: bytes[8..<12], as: UTF8.self)) {
                ext = mime == "image/avif" || String(decoding: bytes[8..<12], as: UTF8.self).hasPrefix("avi") ? "avif" : "heic"
            } else { throw DownloadError.invalidFile }
        } else {
            if bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
                ext = String(decoding: bytes[8..<12], as: UTF8.self) == "qt  " ? "mov" : "mp4"
            } else if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { ext = "webm" }
            else { throw DownloadError.invalidFile }
        }
        return DownloadNaming.safe((name as NSString).deletingPathExtension + "." + ext)
    }
}
