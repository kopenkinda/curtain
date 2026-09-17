import AppKit

// Render the same vector used by the app icon, without the app tile's padding.
let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 54, pixelsHigh: 54,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
source.draw(in: NSRect(x: 0, y: 0, width: 54, height: 54),
            from: NSRect(x: 192, y: 192, width: 640, height: 640),
            operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
