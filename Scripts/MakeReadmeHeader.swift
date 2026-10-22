import AppKit

// Draws the README header (1280 x 480 points at 2x) in light and dark:
//   swift Scripts/MakeReadmeHeader.swift <icon.png> <output folder>
// The icon is a render of Resources/AppIcon.icon, made with Icon Composer's ictool.
let icon = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Palette {
    let card: NSColor, edge: NSColor, glow: NSColor, title: NSColor, subtitle: NSColor
}

let light = Palette(card: color(0xFBFCF8), edge: color(0x000000, 0.07), glow: color(0xA3E635, 0.22),
                    title: color(0x111410), subtitle: color(0x111410, 0.48))
let dark = Palette(card: color(0x0A0C09), edge: color(0xFFFFFF, 0.09), glow: color(0x84CC16, 0.20),
                   title: color(0xF7FAF2), subtitle: color(0xF7FAF2, 0.50))

func centred(_ text: String, font: NSFont, color: NSColor, kern: CGFloat, top: CGFloat, in size: NSSize) {
    let line = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    let bounds = line.size()
    line.draw(at: NSPoint(x: (size.width - bounds.width + kern) / 2, y: size.height - top - bounds.height))
}

func draw(_ palette: Palette, size: NSSize) {
    let card = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
    palette.card.setFill(); card.fill()
    NSGraphicsContext.saveGraphicsState()
    card.addClip()
    // A soft lime glow behind the icon, fading out well before the edges.
    let iconCentre = NSPoint(x: size.width / 2, y: size.height - 160)
    NSGradient(colors: [palette.glow, palette.glow.withAlphaComponent(0)])!
        .draw(fromCenter: iconCentre, radius: 0, toCenter: iconCentre, radius: 280, options: [])
    NSGraphicsContext.restoreGraphicsState()
    palette.edge.setStroke(); card.lineWidth = 1; card.stroke()

    icon.draw(in: NSRect(x: iconCentre.x - 92, y: iconCentre.y - 92, width: 184, height: 184))
    centred("Lime", font: .systemFont(ofSize: 76, weight: .semibold), color: palette.title, kern: -2.2, top: 268, in: size)
    centred("Drag a file, tap a key, pick a petal.", font: .systemFont(ofSize: 21, weight: .regular),
            color: palette.subtitle, kern: -0.1, top: 372, in: size)
}

for (name, palette) in [("header-light.png", light), ("header-dark.png", dark)] {
    let points = NSSize(width: 1280, height: 480)
    // Display P3, like the icon render, so its lime green is not clipped to sRGB.
    let ctx = CGContext(data: nil, width: Int(points.width) * 2, height: Int(points.height) * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(palette, size: points)
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
