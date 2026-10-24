import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image decoding and encoding helpers shared by conversions and tools.
enum ImageIOKit {
    static let typeIdentifiers: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff",
        "bmp": "com.microsoft.bmp", "avif": "public.avif", "gif": "com.compuserve.gif",
    ]

    /// Decodes the first frame with orientation applied (SVG via AppKit).
    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if FormatCatalog.format(of: url) == "svg" { return try renderSVG(url, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw LimeError("\(url.lastPathComponent) isn't a readable picture.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let limit = maxPixelSize ?? max(w, h, 1)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, limit)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LimeError("\(url.lastPathComponent) isn't a readable picture.")
        }
        return image
    }

    static func renderSVG(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw LimeError("Lime couldn't draw the vector file \(url.lastPathComponent).")
        }
        let longest = max(image.size.width, image.size.height)
        let target = CGFloat(maxPixelSize ?? 2048)
        let scale = max(1, min(target / longest, 8))
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard let context = makeContext(width: width, height: height) else { throw LimeError("The vector file has a broken size.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw LimeError("Vector artwork could not be rasterized.") }
        return result
    }

    static func makeContext(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        guard width > 0, height > 0, width <= 32768, height <= 32768 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)
    }

    static func properties(_ url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    /// Properties safe to copy after the pixels were orientation-normalised.
    static func portableMetadata(_ url: URL) -> [String: Any] {
        var props = properties(url)
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
                    kCGImagePropertyHasAlpha, kCGImagePropertyProfileName, kCGImagePropertyPNGDictionary, kCGImagePropertyJFIFDictionary] {
            props.removeValue(forKey: key as String)
        }
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return props
    }

    static func flattened(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height, opaque: true) else { return image }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    static func resized(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxDimension > 0, longest > maxDimension else { return image }
        let ratio = Double(maxDimension) / Double(longest)
        return resized(image, width: max(1, Int(Double(image.width) * ratio)), height: max(1, Int(Double(image.height) * ratio)))
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard let context = makeContext(width: width, height: height) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func canWrite(_ format: String) -> Bool {
        if format == "webp" || format == "pdf" { return true }
        guard let identifier = typeIdentifiers[format] else { return false }
        return (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(identifier)
    }

    /// Encodes one image. WebP uses libwebp through the bundled ffmpeg.
    static func write(_ image: CGImage, to destination: URL, format: String, quality: Double,
                      metadata: [String: Any] = [:], pngLevel: Int = 6) async throws {
        switch format {
        case "webp":
            // An uncompressed TIFF hands the pixels over without spending time on
            // deflate. ImageIO stores TIFF transparency premultiplied, which ffmpeg
            // reads as straight and darkens, so see-through pictures go as PNG.
            let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let intermediate = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + (opaque ? ".tiff" : ".png"))
            defer { try? FileManager.default.removeItem(at: intermediate) }
            if opaque {
                try writeImageIO(image, to: intermediate, format: "tiff", quality: 1,
                                 metadata: [kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFCompression as String: 1]])
            } else {
                try writeImageIO(image, to: intermediate, format: "png", quality: 1, metadata: [:])
            }
            let lossless = quality >= 0.999
            // libwebp's default effort (4) is about twice as fast as its slowest
            // (6), for files about a tenth larger at usual quality and a quarter
            // larger at low quality, so the slowest is kept for Smaller File and
            // Smallest File.
            let slowest = pngLevel >= 8 || quality <= ConvertPrefs.Quality.smaller.value
            try await FFmpeg.run(["-i", intermediate.path, "-frames:v", "1", "-c:v", "libwebp",
                                  "-lossless", lossless ? "1" : "0", "-quality", String(Int(quality * 100)),
                                  "-compression_level", slowest ? "6" : "4", destination.path], duration: 0, context: nil)
        case "pdf":
            try writePDF([image], to: destination)
        case "jpg", "bmp":
            try writeImageIO(flattened(image), to: destination, format: format, quality: quality, metadata: metadata)
        default:
            try writeImageIO(image, to: destination, format: format, quality: quality, metadata: metadata)
            if format == "png", pngLevel >= 8 { try? PNGOptimizer.optimize(destination) }
        }
    }

    static func writeImageIO(_ image: CGImage, to destination: URL, format: String, quality: Double, metadata: [String: Any]) throws {
        guard let identifier = typeIdentifiers[format], canWrite(format),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, identifier as CFString, 1, nil) else {
            throw LimeError("Lime couldn't encode a \(FormatCatalog.label(format)) picture.")
        }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(writer, image, props as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw LimeError("Lime couldn't finish writing the picture.") }
    }

    /// A JPEG that needs no turning goes into a PDF as its original bytes,
    /// with no decode or re-encode; anything else is decoded as usual.
    static func pdfImage(_ url: URL) throws -> CGImage {
        // An undecoded JPEG image from ImageIO is written to the PDF as its own data.
        if FormatCatalog.format(of: url) == "jpg", (properties(url)[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
            return image
        }
        return try load(url)
    }

    /// One page per image at 72 points per pixel-inch, matching Preview.
    static func writePDF(_ images: [CGImage], to destination: URL, dpi: Double = 144) throws {
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw LimeError("Lime couldn't write the PDF.") }
        for image in images {
            try Task.checkCancellation()
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    static func pixelDPI(_ url: URL) -> Double {
        let props = properties(url)
        let dpi = props[kCGImagePropertyDPIWidth as String] as? Double ?? 72
        return dpi > 0 ? dpi : 72
    }
}

/// Lossless PNG recompression: drops ancillary chunks and re-deflates IDAT.
enum PNGOptimizer {
    static func optimize(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count > 8, Array(data.prefix(8)) == signature else { return }
        var offset = 8
        var kept = Data(signature)
        while offset + 12 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            let end = offset + 12 + length
            guard end <= data.count else { return }
            if ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "acTL", "fcTL", "fdAT"].contains(type) {
                kept.append(data[offset..<end])
            }
            offset = end
        }
        if kept.count < data.count { try kept.write(to: url, options: .atomic) }
    }
}
