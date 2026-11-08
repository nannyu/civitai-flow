import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import FlowCore

struct PhotoSaveReceipt: Sendable {
    let localIdentifier: String
}

enum PhotoSaver {
    @discardableResult
    static func save(_ post: MediaPost, downloader: any FileDownloading = FileDownloader()) async throws -> PhotoSaveReceipt {
        try await authorize()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Photos must finish copying its resource before this directory can be removed.
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try DownloadPlan.media(post)
        guard let asset = plan.assets.first else { throw SaveError.download }
        let name = try await downloader.download(asset, to: directory, token: nil) { _ in }
        try Task.checkCancellation()
        return try await saveFile(directory.appendingPathComponent(name), isVideo: post.isVideo)
    }

    @discardableResult
    static func saveFile(_ file: URL, isVideo: Bool) async throws -> PhotoSaveReceipt {
        try await authorize()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = try await compatibleResource(file, isVideo: isVideo, directory: directory)
        try Task.checkCancellation()
        let importedAt = Date()
        let result = CreatedPhoto()
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // Imported EXIF/QuickTime dates can otherwise put a new save years back in the library.
                request.creationDate = importedAt
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = resource.lastPathComponent
                options.shouldMoveFile = false
                request.addResource(with: isVideo ? .video : .photo, fileURL: resource, options: options)
                result.set(request.placeholderForCreatedAsset?.localIdentifier)
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: SaveError.library(error.localizedDescription)) }
                else if success, let identifier = result.identifier {
                    continuation.resume(returning: PhotoSaveReceipt(localIdentifier: identifier))
                } else { continuation.resume(throwing: SaveError.notCreated) }
            }
        }
    }

    private static func authorize() async throws {
        let existing = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = existing == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : existing
        guard status == .authorized || status == .limited else { throw SaveError.permission }
    }

    private static func compatibleResource(_ file: URL, isVideo: Bool, directory: URL) async throws -> URL {
        if isVideo {
            if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file.path) { return file }
            let asset = AVURLAsset(url: file)
            guard (try? await asset.load(.isPlayable)) == true,
                  let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                  exporter.supportedFileTypes.contains(.mp4) else { throw SaveError.unsupportedVideo }
            let converted = directory.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-photos.mp4")
            exporter.outputURL = converted
            exporter.outputFileType = .mp4
            await exporter.export()
            try Task.checkCancellation()
            guard exporter.status == .completed, UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(converted.path) else {
                throw SaveError.unsupportedVideo
            }
            return converted
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let identifier = CGImageSourceGetType(source) else { throw SaveError.unsupportedImage }
        // Header-only images can report a complete source until ImageIO attempts to decode pixels.
        // A small thumbnail validates the resource without retaining a full-resolution bitmap.
        let validationOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, validationOptions as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw SaveError.unsupportedImage }
        // Keep original bytes (including GIF animation) for Photos-native image formats.
        if let type = UTType(identifier as String), [UTType.jpeg, .png, .gif, .heic, .heif, .tiff].contains(type) { return file }
        // CDNs can negotiate WebP/AVIF even when the source URL ends in .jpg.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SaveError.unsupportedImage }
        let converted = directory.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-photos.png")
        guard let destination = CGImageDestinationCreateWithURL(converted as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SaveError.unsupportedImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = properties?[kCGImagePropertyOrientation as String] as? Int ?? 1
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SaveError.unsupportedImage }
        return converted
    }

    enum SaveError: LocalizedError {
        case permission, download, unsupportedImage, unsupportedVideo, notCreated, library(String)
        var errorDescription: String? {
            switch self {
            case .permission: return "请在 iPhone 设置中允许 Flow 添加照片，然后重试。"
            case .download: return "原文件下载失败，请检查网络后重试。"
            case .unsupportedImage: return "这张图片无法导入系统相册，可选择“下载到文件”保存原文件。"
            case .unsupportedVideo: return "这段视频的格式或编码不受系统相册支持，可选择“下载到文件”保存原文件。"
            case .notCreated: return "系统相册未确认创建照片或视频，请稍后重试。"
            case .library(let reason): return "保存到系统相册失败：\(reason)"
            }
        }
    }
}

/// PhotoKit invokes its change and completion blocks on different queues.
private final class CreatedPhoto: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ identifier: String?) { lock.lock(); defer { lock.unlock() }; value = identifier }
    var identifier: String? { lock.lock(); defer { lock.unlock() }; return value }
}
