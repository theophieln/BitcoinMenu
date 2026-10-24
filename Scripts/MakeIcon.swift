import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                            xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.systemOrange.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 1, green: 0.69, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.95, green: 0.39, blue: 0.04, alpha: 1))!
        .draw(in: tile, angle: -90)

    let transform = NSAffineTransform()
    transform.translateX(by: 512, yBy: 512)
    transform.rotate(byDegrees: -12)
    transform.concat()
    let symbol = NSAttributedString(string: "₿", attributes: [
        .font: NSFont.systemFont(ofSize: 610, weight: .bold),
        .foregroundColor: NSColor.white
    ])
    let bounds = symbol.size()
    symbol.draw(at: NSPoint(x: -bounds.width / 2, y: -bounds.height / 2 + 8))
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: output).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try drawIcon(size: size * scale).write(to: url)
    }
}
