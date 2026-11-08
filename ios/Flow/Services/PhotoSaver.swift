import Foundation
import Photos
import FlowCore

enum PhotoSaver {
    static func save(_ post: MediaPost) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.permission }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try DownloadPlan.media(post)
        guard let asset = plan.assets.first else { throw SaveError.download }
        let name = try await FileDownloader().download(asset, to: directory, token: nil) { _ in }
        let local = directory.appendingPathComponent(name)
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: post.isVideo ? .video : .photo, fileURL: local, options: nil)
        }
    }

    enum SaveError: LocalizedError {
        case permission, download
        var errorDescription: String? {
            switch self {
            case .permission: return "请在 iPhone 设置中允许 Flow 添加照片，然后重试。"
            case .download: return "原文件下载失败，请检查网络后重试。"
            }
        }
    }
}
