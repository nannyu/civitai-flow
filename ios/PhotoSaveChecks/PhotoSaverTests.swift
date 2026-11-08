import XCTest
import Photos
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import FlowCore
@testable import PhotoSaveCheckHost

final class PhotoSaverTests: XCTestCase {
    override func setUp() async throws {
        // Only this isolated test host asks for read access; the production app remains add-only.
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        print("Photo check host: \(Bundle.main.bundleIdentifier ?? "nil"), read/write: \(status.rawValue), add-only: \(PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue)")
        XCTAssertEqual(status, .authorized)
    }
    func testOldEXIFDateDoesNotHideNewImportAndOriginalSurvivesCleanup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try imageFile(in: directory, type: .jpeg)
        // Record the old behavior, without assuming how any particular iOS version chooses its default date.
        let legacyID = CreatedAssetID()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: file, options: nil)
            legacyID.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        let oldAsset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [try XCTUnwrap(legacyID.value)], options: nil).firstObject)
        print("Legacy import creation date: \(String(describing: oldAsset.creationDate))")
        let started = Date()
        let receipt = try await PhotoSaver.saveFile(file, isVideo: false)
        let asset = try fetch(receipt)
        XCTAssertEqual(asset.mediaType, .image)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(asset.creationDate), started.addingTimeInterval(-1))
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first)
        XCTAssertEqual(resource.originalFilename, file.lastPathComponent)
        try FileManager.default.removeItem(at: file)
        let recovered = directory.appendingPathComponent("recovered.jpg")
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: recovered, options: nil)
        XCTAssertNotNil(CGImageSourceCreateWithURL(recovered as CFURL, nil))
    }

    func testDownloadPathDoesNotReportSuccessBeforePhotosCopiesTheImage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try imageFile(in: directory, type: .png)
        let post = try JSONDecoder().decode(MediaPost.self, from: Data(#"{"id":1234,"url":"https://image.civitai.com/test.png","type":"image","browsingLevel":1}"#.utf8))
        let receipt = try await PhotoSaver.save(post, downloader: LocalDownload(file: file))
        let asset = try fetch(receipt)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first)
        XCTAssertEqual(resource.originalFilename, "civitai-1234.png")
        let recovered = directory.appendingPathComponent("after-temp-cleanup.png")
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: recovered, options: nil)
        XCTAssertNotNil(CGImageSourceCreateWithURL(recovered as CFURL, nil))
    }

    func testNonNativeImageIsConvertedToPNGBeforeImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try imageFile(in: directory, type: .bmp)
        let receipt = try await PhotoSaver.saveFile(file, isVideo: false)
        let asset = try fetch(receipt)
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first)
        XCTAssertEqual(resource.uniformTypeIdentifier, UTType.png.identifier)
        XCTAssertEqual(resource.originalFilename, "old-date-photos.png")
        XCTAssertEqual(asset.pixelWidth, 64)
        XCTAssertEqual(asset.pixelHeight, 64)
    }

    func testActualH264VideoIsCommittedWithAnImportDate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await videoFile(in: directory)
        let started = Date()
        let receipt = try await PhotoSaver.saveFile(file, isVideo: true)
        let asset = try fetch(receipt)
        XCTAssertEqual(asset.mediaType, .video)
        XCTAssertGreaterThan(asset.duration, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(asset.creationDate), started.addingTimeInterval(-1))
        let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first)
        try FileManager.default.removeItem(at: file)
        let recovered = directory.appendingPathComponent("recovered.mp4")
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: recovered, options: nil)
        let exported = AVURLAsset(url: recovered)
        let playable = try await exported.load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testInvalidImageAndVideoCannotReturnASuccessReceipt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("broken.jpg")
        try Data("not media".utf8).write(to: file)
        for video in [false, true] {
            do { _ = try await PhotoSaver.saveFile(file, isVideo: video); XCTFail("Invalid media was reported as saved") }
            catch is PhotoSaver.SaveError {}
        }
    }

    func testTruncatedNativeImageIsRejectedBeforePhotosImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try imageFile(in: directory, type: .png)
        let bytes = try Data(contentsOf: file)
        try Data(bytes.prefix(40)).write(to: file)
        do { _ = try await PhotoSaver.saveFile(file, isVideo: false); XCTFail("Truncated PNG was reported as saved") }
        catch PhotoSaver.SaveError.unsupportedImage {}
    }

    private func fetch(_ receipt: PhotoSaveReceipt) throws -> PHAsset {
        try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [receipt.localIdentifier], options: nil).firstObject)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func imageFile(in directory: URL, type: UTType) throws -> URL {
        let file = directory.appendingPathComponent("old-date.\(type.preferredFilenameExtension ?? "img")")
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2001:01:02 03:04:05", kCGImagePropertyExifDateTimeDigitized: "2001:01:02 03:04:05"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2001:01:02 03:04:05"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return file
    }
    private func videoFile(in directory: URL) async throws -> URL {
        let file = directory.appendingPathComponent("old-video.mp4")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let date = AVMutableMetadataItem(); date.identifier = .commonIdentifierCreationDate; date.value = "2001-01-02T03:04:05Z" as NSString
        writer.metadata = [date]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<5 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 30), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return file
    }
}

private struct LocalDownload: FileDownloading {
    let file: URL
    func download(_ asset: DownloadAsset, to directory: URL, token: String?, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> String {
        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(asset.name))
        return asset.name
    }
}

private final class CreatedAssetID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
