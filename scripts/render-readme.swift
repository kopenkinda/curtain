#!/usr/bin/env swift
import AppKit

// Run from the repository root: xcrun swift scripts/render-readme.swift
// Uses the real Icon Composer asset and native macOS typography.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Artwork/readme/banner.png")
let temporary = root.appendingPathComponent(".build/readme")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconURL = temporary.appendingPathComponent("Curtain-dark.png")
let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
let export = Process()
export.executableURL = URL(fileURLWithPath: developer).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
export.arguments = ["Artwork/Curtain.icon", "--export-image", "--output-file", iconURL.path,
                    "--platform", "macOS", "--rendition", "Dark", "--width", "512",
                    "--height", "512", "--scale", "1", "--design-generation", "27"]
try export.run()
export.waitUntilExit()
precondition(export.terminationStatus == 0, "Icon export failed")
let icon = NSImage(contentsOf: iconURL)!
let width = 2048, height = 1012
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.translateBy(x: 0, y: CGFloat(height))
context.cgContext.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func rounded(_ rect: NSRect, radius: CGFloat, fill: UInt32, stroke: UInt32? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color(fill).setFill(); path.fill()
    if let stroke { color(stroke).setStroke(); path.lineWidth = 2; path.stroke() }
}
func text(_ value: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
          fill: UInt32 = 0xf5f6f7, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(fill), .paragraphStyle: style]
    // NSString drawing uses an unflipped graphics context.
    context.saveGraphicsState()
    context.cgContext.translateBy(x: rect.minX, y: rect.minY + rect.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    (value as NSString).draw(in: NSRect(x: 0, y: 0, width: rect.width, height: rect.height),
                            withAttributes: attributes)
    context.restoreGraphicsState()
}
func drawIcon(_ rect: NSRect) {
    context.saveGraphicsState()
    context.cgContext.translateBy(x: rect.minX, y: rect.maxY)
    context.cgContext.scaleBy(x: 1, y: -1)
    icon.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero,
              operation: .sourceOver, fraction: 1)
    context.restoreGraphicsState()
}
func line(_ points: [NSPoint], stroke: UInt32, width: CGFloat = 2) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    color(stroke).setStroke(); path.stroke()
}
func arrow(_ x: CGFloat) {
    line([NSPoint(x: x, y: 632), NSPoint(x: x + 34, y: 632)], stroke: 0x6a737e, width: 3.5)
    line([NSPoint(x: x + 23, y: 621), NSPoint(x: x + 34, y: 632),
          NSPoint(x: x + 23, y: 643)], stroke: 0x6a737e, width: 3.5)
}

color(0x0e1418).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
drawIcon(NSRect(x: 102, y: 87, width: 205, height: 205))
text("Curtain", NSRect(x: 350, y: 94, width: 1200, height: 112), size: 86, weight: .semibold)
text("Lid closed. Mac awake.", NSRect(x: 353, y: 218, width: 1300, height: 52),
     size: 36, weight: .medium, fill: 0xa0a2a6)
for (x, label) in [(102.0, "1  HOLD OPTION"), (742.0, "2  LOWER THE LID"), (1382.0, "3  KEEP WORKING")] {
    rounded(NSRect(x: x, y: 376, width: 564, height: 502), radius: 34, fill: 0x191918)
    text(label, NSRect(x: x + 36, y: 411, width: 492, height: 36), size: 23, weight: .semibold, fill: 0x929497)
}
rounded(NSRect(x: 275, y: 531, width: 218, height: 210), radius: 34, fill: 0x101317, stroke: 0x343b45)
rounded(NSRect(x: 281, y: 539, width: 206, height: 190), radius: 30, fill: 0x2b3038, stroke: 0x66707d)
text("⌥", NSRect(x: 293, y: 558, width: 182, height: 122), size: 94, weight: .medium, alignment: .center)
text("option", NSRect(x: 293, y: 680, width: 182, height: 34), size: 24, fill: 0xaab0b8, alignment: .center)
arrow(686)
// Illustrative laptop with a descending black curtain.
rounded(NSRect(x: 862, y: 526, width: 324, height: 202), radius: 15, fill: 0x090b0e, stroke: 0x626c79)
rounded(NSRect(x: 872, y: 536, width: 304, height: 182), radius: 7, fill: 0x344959)
rounded(NSRect(x: 872, y: 536, width: 304, height: 113), radius: 7, fill: 0x000000)
line([NSPoint(x: 878, y: 649), NSPoint(x: 1170, y: 649)], stroke: 0x8a949f, width: 2)
rounded(NSRect(x: 831, y: 733, width: 386, height: 12), radius: 6, fill: 0x727c87)
line([NSPoint(x: 1009, y: 669), NSPoint(x: 1024, y: 684), NSPoint(x: 1039, y: 669)], stroke: 0xc2ccd7, width: 3)
arrow(1326)
// Fully closed laptop, with a small activity trace above it.
rounded(NSRect(x: 1484, y: 685, width: 360, height: 13), radius: 6, fill: 0x727c87)
rounded(NSRect(x: 1473, y: 703, width: 382, height: 15), radius: 7, fill: 0x333c46, stroke: 0x65717e)
line([NSPoint(x: 1579, y: 603), NSPoint(x: 1614, y: 603), NSPoint(x: 1635, y: 574),
      NSPoint(x: 1655, y: 626), NSPoint(x: 1677, y: 590), NSPoint(x: 1693, y: 603),
      NSPoint(x: 1749, y: 603)], stroke: 0x92b5a8, width: 5)
for (x, caption) in [(126.0, "Hold the key as you close."),
                     (766.0, "A soft tone means it stays active."),
                     (1406.0, "Fully shut. Still running.")] {
    text(caption, NSRect(x: x, y: 787, width: 516, height: 40),
         size: 28, fill: 0xa0a2a6, alignment: .center)
}
text("Native Swift · macOS 27", NSRect(x: 102, y: 938, width: 1600, height: 38),
     size: 26, fill: 0x777c80)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Rendered \(output.path)")
