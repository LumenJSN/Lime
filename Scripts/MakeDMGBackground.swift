import AppKit

// Draws the DMG window background (600 x 380 points, at 1x and 2x) into a
// folder: a pale lime wash, an arrow from the app to Applications, and a hint.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(size: NSSize) {
    NSGradient(starting: color(0xF6FCEE), ending: color(0xE2F4C9))!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    // Arrow between the icons, which sit at x 160 and 440, 190 from the top.
    let y = size.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 252, y: y))
    arrow.line(to: NSPoint(x: 340, y: y))
    arrow.move(to: NSPoint(x: 326, y: y + 13))
    arrow.line(to: NSPoint(x: 344, y: y))
    arrow.line(to: NSPoint(x: 326, y: y - 13))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0x65A30D, 0.85).setStroke()
    arrow.stroke()
    let hint = NSAttributedString(string: "Drag Lime into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: color(0x3F5F14, 0.75),
    ])
    let width = hint.size().width
    hint.draw(at: NSPoint(x: (size.width - width) / 2, y: 52))
}

for scale in [1, 2] {
    let points = NSSize(width: 600, height: 380)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(points.width) * scale, pixelsHigh: Int(points.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: points)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
