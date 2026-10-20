import AppKit

// Draws the Lime app icon (a lime slice on a pale tile) into an .iconset
// folder; `iconutil -c icns` turns it into Resources/AppIcon.icns.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let centre = CGPoint(x: 512, y: 512)
    // Tile with a soft shadow, as on the macOS icon grid.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tile); ctx.setFillColor(color(0xF4FAEA)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let tileGradient = CGGradient(colorsSpace: space, colors: [color(0xFBFDF6), color(0xDDEFC6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(tileGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Rind, pith ring and slice shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x2C5A0A, 0.35))
    ctx.setFillColor(color(0x4A9E12)); ctx.fillEllipse(in: CGRect(x: 182, y: 182, width: 660, height: 660))
    ctx.restoreGState()
    let rind = CGGradient(colorsSpace: space, colors: [color(0x72C21C), color(0x3F8A10)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 182, y: 182, width: 660, height: 660)); ctx.clip()
    ctx.drawLinearGradient(rind, start: CGPoint(x: 300, y: 842), end: CGPoint(x: 724, y: 182), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xF2F9DC)); ctx.fillEllipse(in: CGRect(x: 214, y: 214, width: 596, height: 596))

    // Ten juicy segments separated by pith.
    let segments = 10, outer: CGFloat = 276, inner: CGFloat = 46, gap: CGFloat = 9
    let flesh = CGGradient(colorsSpace: space, colors: [color(0xD9F27E), color(0xA6DA3E), color(0x86C52A)] as CFArray, locations: [0, 0.55, 1])!
    for i in 0..<segments {
        let a0 = CGFloat(i) / CGFloat(segments) * 2 * .pi + .pi / 2
        let a1 = a0 + 2 * .pi / CGFloat(segments)
        let mid = (a0 + a1) / 2
        let offset = CGPoint(x: centre.x + cos(mid) * gap, y: centre.y + sin(mid) * gap)
        let path = CGMutablePath()
        path.addArc(center: offset, radius: outer - gap, startAngle: a0 + 0.035, endAngle: a1 - 0.035, clockwise: false)
        path.addArc(center: offset, radius: inner, startAngle: a1 - 0.2, endAngle: a0 + 0.2, clockwise: true)
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawRadialGradient(flesh, startCenter: centre, startRadius: inner, endCenter: centre, endRadius: outer, options: [])
        // Juice sacs: faint radial streaks.
        ctx.setStrokeColor(color(0xFFFFFF, 0.22)); ctx.setLineWidth(5); ctx.setLineCap(.round)
        for k in 1...3 {
            let a = a0 + (a1 - a0) * CGFloat(k) / 4
            ctx.move(to: CGPoint(x: centre.x + cos(a) * (inner + 40), y: centre.y + sin(a) * (inner + 40)))
            ctx.addLine(to: CGPoint(x: centre.x + cos(a) * (outer - 50), y: centre.y + sin(a) * (outer - 50)))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.setFillColor(color(0xF2F9DC)); ctx.fillEllipse(in: CGRect(x: centre.x - 30, y: centre.y - 30, width: 60, height: 60))

    // Gloss on the upper left of the slice.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 182, y: 182, width: 660, height: 660)); ctx.clip()
    let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 380, y: 680), startRadius: 0, endCenter: CGPoint(x: 380, y: 680), endRadius: 330, options: [])
    ctx.restoreGState()
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high
    draw(in: ctx)
    let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: destination.appendingPathComponent(name)) }
}
