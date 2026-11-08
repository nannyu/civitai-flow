// Run from ios/: swift scripts/GenerateIcon.swift
// Package the selected imagegen artwork; resizing does not redraw the logo.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: "design/brand/flow-icon-source.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Missing Flow brand artwork") }
let catalog = URL(fileURLWithPath: "Flow/Resources/Assets.xcassets", isDirectory: true)
for (path, side) in [("AppIcon.appiconset/AppIcon.png", 1024), ("FlowLogo.imageset/FlowLogo.png", 512)] {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let destination = catalog.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not package logo") }
    print("Packaged \(destination.lastPathComponent): \(side) × \(side), RGB")
}
