import AppKit

/// Draws annotations into a y-down context sized to the image's pixels.
enum AnnotationRenderer {
    static func render(_ image: CGImage, annotations: [Markup]) throws -> CGImage {
        guard let context = ImageIOKit.makeContext(width: image.width, height: image.height) else { throw LimeError("Lime couldn't draw the markup onto the photo.") }
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, source: image)
        guard let output = context.makeImage() else { throw LimeError("Lime couldn't draw the markup onto the photo.") }
        return output
    }

    /// `context` must already be y-down in image pixel units.
    static func draw(_ annotations: [Markup], in context: CGContext, source: CGImage?) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for a in annotations { draw(a, in: context, source: source) }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func draw(_ a: Markup, in context: CGContext, source: CGImage?) {
        let color = a.color.cgColor
        context.saveGState()
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(a.lineWidth)
        switch a.kind {
        case .line:
            context.move(to: a.start); context.addLine(to: a.end); context.strokePath()
        case .arrow:
            let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
            let head = max(a.lineWidth * 4, 18)
            let shaftEnd = CGPoint(x: a.end.x - cos(angle) * head * 0.6, y: a.end.y - sin(angle) * head * 0.6)
            context.move(to: a.start); context.addLine(to: shaftEnd); context.strokePath()
            context.move(to: a.end)
            context.addLine(to: CGPoint(x: a.end.x - head * cos(angle - .pi / 7), y: a.end.y - head * sin(angle - .pi / 7)))
            context.addLine(to: CGPoint(x: a.end.x - head * cos(angle + .pi / 7), y: a.end.y - head * sin(angle + .pi / 7)))
            context.closePath(); context.fillPath()
        case .rectangle:
            context.addPath(CGPath(roundedRect: rect(a), cornerWidth: a.lineWidth, cornerHeight: a.lineWidth, transform: nil)); context.strokePath()
        case .ellipse:
            context.strokeEllipse(in: rect(a))
        case .highlight:
            context.setFillColor(a.color.cgColor.copy(alpha: 0.35) ?? color)
            context.setBlendMode(.multiply)
            context.fill(rect(a))
        case .draw:
            guard let first = a.points.first else { break }
            context.move(to: first)
            for p in a.points.dropFirst() { context.addLine(to: p) }
            context.strokePath()
        case .text:
            let font = NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .orange]
            let width = max(40, abs(a.end.x - a.start.x))
            (a.text as NSString).draw(with: CGRect(x: min(a.start.x, a.end.x), y: a.start.y, width: width, height: 10_000),
                                      options: [.usesLineFragmentOrigin], attributes: attributes)
        case .number:
            let radius = max(a.fontSize * 0.75, 18)
            let circle = CGRect(x: a.start.x - radius, y: a.start.y - radius, width: radius * 2, height: radius * 2)
            context.fillEllipse(in: circle)
            let label = "\(a.number)" as NSString
            let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attributes)
        case .image:
            guard let url = a.imageURL, let picture = try? ImageIOKit.load(url, maxPixelSize: 4096) else { break }
            let box = rect(a)
            context.saveGState()
            // Image rows are top-down here; flip the picture back for drawing.
            context.translateBy(x: 0, y: box.maxY + box.minY); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(picture, in: box)
            context.restoreGState()
        case .magnifier:
            guard let source else { break }
            let radius = max(30, hypot(a.end.x - a.start.x, a.end.y - a.start.y))
            let sampleRadius = radius / max(1.2, a.zoom)
            let sample = CGRect(x: a.start.x - sampleRadius, y: a.start.y - sampleRadius, width: sampleRadius * 2, height: sampleRadius * 2)
            let bubble = CGRect(x: a.start.x - radius, y: a.start.y - radius, width: radius * 2, height: radius * 2)
            if let crop = source.cropping(to: sample.integral) {
                context.saveGState()
                context.addEllipse(in: bubble); context.clip()
                // Image rows are top-down here; flip the tile back for drawing.
                context.translateBy(x: 0, y: bubble.maxY + bubble.minY); context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(crop, in: bubble)
                context.restoreGState()
            }
            context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(max(4, radius * 0.06))
            context.setShadow(offset: .zero, blur: radius * 0.15, color: CGColor(gray: 0, alpha: 0.45))
            context.strokeEllipse(in: bubble)
        }
        context.restoreGState()
    }

    static func rect(_ a: Markup) -> CGRect {
        CGRect(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y), width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y))
    }
}

/// Add BG: places the photo on a background with ratio, padding and corners.
enum FrameRenderer {
    /// `unit` converts the option pixels when `image` is a scaled preview.
    static func render(_ image: CGImage, options o: BackdropSettings, maxPixels: Int = 8192, unit: CGFloat = 1) throws -> CGImage {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let pad = CGFloat(o.padding) * unit
        var cw = iw + pad * 2, ch = ih + pad * 2
        if let ratio = o.canvasShape.ratio {
            if cw / ch > ratio { ch = cw / ratio } else { cw = ch * ratio }
        }
        let scale = min(1, CGFloat(maxPixels) / max(cw, ch))
        let width = Int((cw * scale).rounded()), height = Int((ch * scale).rounded())
        guard let context = ImageIOKit.makeContext(width: width, height: height) else {
            throw LimeError("The result would be too big. Use less padding or a ratio nearer the photo's.")
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        try drawBackground(o.background, in: context, rect: canvas)
        let photo = CGRect(x: (CGFloat(width) - iw * scale) / 2, y: (CGFloat(height) - ih * scale) / 2, width: iw * scale, height: ih * scale)
        let radius = min(min(photo.width, photo.height) / 2, CGFloat(o.cornerRadius) * unit * scale)
        let path = CGPath(roundedRect: photo, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if o.shadowRadius > 0 {
            context.saveGState()
            let blur = CGFloat(o.shadowRadius) * unit * scale
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur, color: CGColor(gray: 0, alpha: 0.35))
            context.addPath(path); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path); context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: photo)
        context.restoreGState()
        guard let output = context.makeImage() else { throw LimeError("Lime couldn't finish the background.") }
        return output
    }

    static func drawBackground(_ background: BackdropSettings.Background, in context: CGContext, rect: CGRect) throws {
        switch background {
        case .color(let color):
            context.setFillColor(color.cgColor); context.fill(rect)
        case .preset(let name):
            if let solid = FramePresets.colors.first(where: { $0.0 == name }) {
                context.setFillColor(RGBColor(hex: solid.1).cgColor); context.fill(rect); return
            }
            let stops = FramePresets.gradients.first(where: { $0.0 == name })?.1 ?? FramePresets.gradients[0].1
            let colors = stops.map { RGBColor(hex: $0).cgColor } as CFArray
            let locations = stops.indices.map { CGFloat($0) / CGFloat(max(1, stops.count - 1)) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            if stops.count > 2 {
                // Three-stop gradients get a soft highlight in the upper left.
                let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
                context.drawRadialGradient(glow, startCenter: CGPoint(x: rect.width * 0.3, y: rect.height * 0.7), startRadius: 0,
                                           endCenter: CGPoint(x: rect.width * 0.3, y: rect.height * 0.7), endRadius: max(rect.width, rect.height) * 0.6, options: [])
            }
        case .image(let url):
            let bg = try ImageIOKit.load(url, maxPixelSize: Int(max(rect.width, rect.height)))
            let scale = max(rect.width / CGFloat(bg.width), rect.height / CGFloat(bg.height))
            let size = CGSize(width: CGFloat(bg.width) * scale, height: CGFloat(bg.height) * scale)
            context.draw(bg, in: CGRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

/// Grid, horizontal, vertical and featured collages on a fixed canvas.
enum CollageRenderer {
    static func frames(count: Int, options: MosaicSettings, canvas: CGSize, spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap = spacing
        func row(_ n: Int, in area: CGRect) -> [CGRect] {
            let w = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
            return (0..<n).map { CGRect(x: area.minX + CGFloat($0) * (w + gap), y: area.minY, width: w, height: area.height) }
        }
        let content = CGRect(x: gap, y: gap, width: canvas.width - gap * 2, height: canvas.height - gap * 2)
        switch options.style {
        case .horizontal: return row(count, in: content)
        case .vertical:
            let h = (content.height - gap * CGFloat(count - 1)) / CGFloat(count)
            return (0..<count).map { CGRect(x: content.minX, y: content.minY + CGFloat($0) * (h + gap), width: content.width, height: h) }
        case .grid:
            let columns = max(1, min(count, options.columns))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let h = (content.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            var result: [CGRect] = []
            for r in 0..<rows {
                let inRow = min(columns, count - r * columns)
                let w = (content.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let rowWidth = w * CGFloat(inRow) + gap * CGFloat(inRow - 1)
                let x0 = content.minX + (content.width - rowWidth) / 2
                for c in 0..<inRow { result.append(CGRect(x: x0 + CGFloat(c) * (w + gap), y: content.minY + CGFloat(r) * (h + gap), width: w, height: h)) }
            }
            return result
        case .featured:
            if count == 1 { return [content] }
            let featureHeight = (content.height - gap) * 0.62
            let feature = CGRect(x: content.minX, y: content.minY, width: content.width, height: featureHeight)
            let rest = CGRect(x: content.minX, y: feature.maxY + gap, width: content.width, height: content.height - featureHeight - gap)
            return [feature] + row(count - 1, in: rest)
        }
    }

    static func canvasSize(_ options: MosaicSettings) -> CGSize {
        let width = CGFloat(options.width)
        return CGSize(width: width, height: (width / options.canvas.ratio).rounded())
    }

    static func render(_ images: [CGImage], options: MosaicSettings) throws -> CGImage {
        let size = canvasSize(options)
        guard let context = ImageIOKit.makeContext(width: Int(size.width), height: Int(size.height)) else { throw LimeError("Lime couldn't set up the collage.") }
        context.setFillColor(options.background.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let gap = size.width * CGFloat(options.spacing)
        let frames = frames(count: images.count, options: options, canvas: size, spacing: gap)
        for (image, frame) in zip(images, frames) {
            // Frames are top-left; CoreGraphics is bottom-left.
            let cell = CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height)
            let radius = size.width * CGFloat(options.cornerRadius)
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = options.fillCells ? max(cell.width / iw, cell.height / ih) : min(cell.width / iw, cell.height / ih)
            let drawn = CGRect(x: cell.midX - iw * scale / 2, y: cell.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
            context.saveGState()
            let clipRect = options.fillCells ? cell : drawn
            context.addPath(CGPath(roundedRect: clipRect, cornerWidth: min(radius, clipRect.width / 2), cornerHeight: min(radius, clipRect.height / 2), transform: nil))
            context.clip()
            context.interpolationQuality = .high
            context.draw(image, in: drawn)
            context.restoreGState()
        }
        guard let output = context.makeImage() else { throw LimeError("Lime couldn't draw the collage.") }
        return output
    }
}
