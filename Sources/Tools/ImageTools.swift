import AppKit
import ImageIO
import PDFKit

/// Photo tools: compress, edit, annotate, add background, crop, redact,
/// collage, create PDF and QR reading.
enum ImageTools {
    static func fileSize(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    // MARK: Compress

    static func compress(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let format = FormatCatalog.format(of: source) ?? "jpg"
        let original = fileSize(source)
        guard original >= 1000 else { throw LimeError("This file is under 1 KB already.") }
        if format == "webp", AnimatedImage.frameCount(source) > 1 {
            let target = options.targetBytes(original: original)
            if let target, target < 1000 { throw LimeError("The target size has to be 1 KB or more.") }
            if let target, target >= original { throw LimeError("The target has to be smaller than the file is now.") }
            let output = context.output(for: source, label: "compressed", ext: format)
            return try await AnimatedImage.compressWebP(source, options: options, target: target, original: original, output: output, context: context)
        }
        var image = try ImageIOKit.load(source)
        if let cap = options.resizeCap.maxDimension { image = ImageIOKit.resized(image, maxDimension: cap) }
        var metadata = ImageIOKit.portableMetadata(source)
        let output = context.output(for: source, label: "compressed", ext: format)
        let target = options.targetBytes(original: original)
        if let target {
            guard target >= 1000 else { throw LimeError("The target size has to be 1 KB or more.") }
            guard target < original else { throw LimeError("The target has to be smaller than the file is now.") }
        }
        let lossy = ["jpg", "heic", "webp", "avif"].contains(format)
        func encode(_ img: CGImage, quality: Double, to url: URL) async throws -> Int {
            try? FileManager.default.removeItem(at: url)
            if format == "png" {
                try await quantizedPNG(img, colors: quality > 0.6 ? 256 : quality > 0.35 ? 128 : 64, to: url, workspace: context)
            } else if format == "tiff" {
                try writeTIFF(img, to: url, metadata: metadata)
            } else {
                try await ImageIOKit.write(img, to: url, format: format, quality: quality, metadata: metadata)
            }
            return fileSize(url)
        }
        guard let target else {
            let quality = options.squashLevel == .gentle ? 0.72 : 0.48
            let size = try await encode(image, quality: quality, to: output)
            if size >= original, options.resizeCap == .original { throw LimeError("Compressing wouldn't make this file any smaller than it already is.") }
            return
        }
        // Target size: search quality, then shrink dimensions if needed.
        var smallest = Int.max
        for _ in 0..<8 {
            try Task.checkCancellation()
            if lossy {
                var low = 0.05, high = 0.95, best: Data?
                for _ in 0..<7 {
                    let mid = (low + high) / 2
                    let size = try await encode(image, quality: mid, to: output)
                    smallest = min(smallest, size)
                    if size <= target { low = mid; best = try Data(contentsOf: output) } else { high = mid }
                }
                if let best { try best.write(to: output); return }
            } else {
                let size = try await encode(image, quality: 0.3, to: output)
                smallest = min(smallest, size)
                if size <= target { return }
            }
            // Metadata is dropped before pixels are reduced further.
            if !metadata.isEmpty { metadata = [:]; continue }
            let shrunk = ImageIOKit.resized(image, maxDimension: Int(Double(max(image.width, image.height)) * 0.8))
            guard max(shrunk.width, shrunk.height) >= 32, shrunk.width != image.width else { break }
            image = shrunk
        }
        let formatter = ByteCountFormatter()
        throw LimeError("Lime got it down to \(formatter.string(fromByteCount: Int64(smallest))) but no smaller.")
    }

    static func quantizedPNG(_ image: CGImage, colors: Int, to url: URL, workspace context: OperationContext) async throws {
        let input = context.scratch("png")
        defer { try? FileManager.default.removeItem(at: input) }
        try ImageIOKit.writeImageIO(image, to: input, format: "png", quality: 1, metadata: [:])
        try await FFmpeg.run(["-i", input.path, "-frames:v", "1", "-filter_complex",
                              "[0:v]split[a][b];[a]palettegen=max_colors=\(colors):reserve_transparent=1:stats_mode=single[p];[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128",
                              "-pix_fmt", "pal8", "-compression_level", "100", url.path], duration: 0, context: nil)
        try? PNGOptimizer.optimize(url)
    }

    private static func writeTIFF(_ image: CGImage, to url: URL, metadata: [String: Any]) throws {
        var props = metadata
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression as String] = 5
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        try ImageIOKit.writeImageIO(image, to: url, format: "tiff", quality: 1, metadata: props)
    }

    // MARK: Single-image editors

    static func outputFormat(_ source: URL) -> String {
        let format = FormatCatalog.format(of: source) ?? "png"
        return ImageIOKit.canWrite(format) ? format : "png"
    }

    static func save(_ image: CGImage, source: URL, label: String, format: String? = nil, context: OperationContext) async throws {
        let ext = format ?? outputFormat(source)
        let options = context.optionsForFormat(ext)
        let output = context.output(for: source, label: label, ext: ext)
        let metadata = options.keepTags ? ImageIOKit.portableMetadata(source) : [:]
        try await ImageIOKit.write(image, to: output, format: ext, quality: max(0.9, options.quality), metadata: metadata)
        guard CGImageSourceCreateWithURL(output as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil else {
            throw LimeError("The new picture failed its check, so nothing was saved.")
        }
    }

    static func edit(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let image = try ImageIOKit.load(source)
        try await save(ImageRendering.adjust(image, options.photoTweaks), source: source, label: "edited", context: context)
    }

    static func annotate(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        guard !options.annotations.isEmpty else { throw LimeError("Draw something on the photo first.") }
        let image = try ImageIOKit.load(source)
        try await save(try AnnotationRenderer.render(image, annotations: options.annotations), source: source, label: "annotated", format: "png", context: context)
    }

    static func frame(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let image = try ImageIOKit.load(source)
        let format = outputFormat(source)
        try await save(try FrameRenderer.render(image, options: options.backdropSettings), source: source, label: "background", format: format, context: context)
    }

    static func crop(_ sources: [URL], options: ToolChoices, context: OperationContext) async throws {
        guard let rect = options.cropRect else { throw LimeError("The crop area has an impossible size.") }
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let image = try ImageIOKit.load(source)
            let size = sources.count == 1 ? options.cropPixelSize : nil
            try await save(try ImageRendering.crop(image, rect: rect, outputSize: size), source: source, label: "cropped", context: context)
            context.progress(Double(index + 1) / Double(sources.count))
        }
    }

    static func redact(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        guard !options.redactions.isEmpty else { throw LimeError("Draw a box over what should be hidden.") }
        let image = try ImageIOKit.load(source)
        let output = ImageRendering.redact(image, rects: options.redactions.map(\.rect), style: options.maskFill, color: options.maskColor)
        // Redacted copies never carry the original metadata.
        let ext = outputFormat(source)
        let url = context.output(for: source, label: "redacted", ext: ext)
        try await ImageIOKit.write(output, to: url, format: ext, quality: 0.92, metadata: [:])
    }

    static func collage(_ sources: [URL], options: ToolChoices, context: OperationContext) async throws {
        let ordered = options.orderedFiles ?? sources
        let images = try ordered.map { try ImageIOKit.load($0, maxPixelSize: 3000) }
        let output = try CollageRenderer.render(images, options: options.collage)
        let url = context.output(for: ordered[0], label: "collage", ext: "png")
        try await ImageIOKit.write(output, to: url, format: "png", quality: 1)
    }

    static func imagesToPDF(_ sources: [URL], options: ToolChoices, context: OperationContext) async throws {
        let ordered = options.orderedFiles ?? sources
        guard let consumer = CGDataConsumer(url: context.output(for: ordered[0], label: "combined", ext: "pdf") as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw LimeError("Lime couldn't write the PDF.") }
        for (index, source) in ordered.enumerated() {
            try Task.checkCancellation()
            let image = try ImageIOKit.load(source)
            let dpi = max(72, ImageIOKit.pixelDPI(source))
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(image, in: box)
            pdf.endPage()
            context.progress(Double(index + 1) / Double(ordered.count))
        }
        pdf.closePDF()
    }

    /// Codes found in an image, or on every page of a PDF.
    static func readQRCodes(_ source: URL) throws -> [String] {
        guard FormatCatalog.format(of: source) == "pdf" else { return ImageRendering.qrCodes(in: try ImageIOKit.load(source)) }
        guard let document = PDFDocument(url: source) else { throw LimeError("The PDF could not be opened.") }
        var seen = Set<String>(), codes: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = try? DocumentRenderer.pageImage(page, dpi: 200) else { continue }
            for code in ImageRendering.qrCodes(in: image) where seen.insert(code).inserted { codes.append(code) }
        }
        return codes
    }
}
