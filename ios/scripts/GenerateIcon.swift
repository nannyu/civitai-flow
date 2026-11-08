// Run from ios/: swift scripts/GenerateIcon.swift
// Original vector artwork; the upstream project's images are not bundled.
import AppKit

let side = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
NSColor(srgbRed: 0.96, green: 0.23, blue: 0.32, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()

// Three flowing strokes suggest a lowercase f and a moving feed.
NSColor.white.setStroke()
let stem = NSBezierPath()
stem.lineWidth = 108
stem.lineCapStyle = .round
stem.move(to: NSPoint(x: 384, y: 260))
stem.line(to: NSPoint(x: 384, y: 610))
stem.curve(to: NSPoint(x: 680, y: 736), controlPoint1: NSPoint(x: 384, y: 770), controlPoint2: NSPoint(x: 570, y: 800))
stem.stroke()
let cross = NSBezierPath()
cross.lineWidth = 100
cross.lineCapStyle = .round
cross.move(to: NSPoint(x: 286, y: 526))
cross.curve(to: NSPoint(x: 658, y: 526), controlPoint1: NSPoint(x: 408, y: 565), controlPoint2: NSPoint(x: 536, y: 487))
cross.stroke()
NSColor.white.withAlphaComponent(0.5).setFill()
NSBezierPath(ovalIn: NSRect(x: 612, y: 262, width: 106, height: 106)).fill()
image.unlockFocus()

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: "Flow/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print("Generated \(destination.path)")
