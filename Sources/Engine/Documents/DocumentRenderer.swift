import AppKit
import PDFKit

/// Paginates rich text into PDF and renders PDF pages into images.
enum DocumentRenderer {
    static var defaultPageSize: CGSize {
        let region = Locale.current.region?.identifier ?? "US"
        return ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// TextKit pagination keeps tables, lists and inline images.
    static func renderPDF(_ text: NSAttributedString, to destination: URL, pageSize: CGSize = defaultPageSize, margin: CGFloat = 54) throws {
        let normalized = withDefaults(text)
        let storage = NSTextStorage(attributedString: normalized)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var containers: [NSTextContainer] = []
        repeat {
            try Task.checkCancellation()
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
            guard containers.count < 20_000 else { throw LimeError("The text wouldn't fit on a PDF page.") }
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && layout.glyphRange(for: containers.last!).length > 0
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw LimeError("Lime couldn't write the PDF.") }
        for container in containers {
            let range = layout.glyphRange(for: container)
            if range.length == 0, containers.count > 1 { continue }
            var box = CGRect(origin: .zero, size: pageSize)
            context.beginPage(mediaBox: &box)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
        guard let check = PDFDocument(url: destination), check.pageCount > 0 else { throw LimeError("The finished PDF failed its check.") }
    }

    /// Fills in fonts and colours missing from plain or imported text.
    static func withDefaults(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { result.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil { result.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        // Scale oversized inline images to the text width.
        let maxWidth = defaultPageSize.width - 108
        result.enumerateAttribute(.attachment, in: full) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let size = attachment.bounds.size == .zero ? (attachment.image?.size ?? .zero) : attachment.bounds.size
            if size.width > maxWidth, size.width > 0 {
                attachment.bounds = CGRect(x: 0, y: 0, width: maxWidth, height: size.height * maxWidth / size.width)
            }
        }
        return result
    }

    /// Renders each page at `dpi`; white background for JPEG.
    static func pageImage(_ page: PDFPage, dpi: Double = 300, maxPixels: Double = 8192) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? bounds.height : bounds.width, h = rotated ? bounds.width : bounds.height
        guard w > 0, h > 0 else { throw LimeError("One PDF page has a broken size, so Lime couldn't draw it.") }
        let scale = min(dpi / 72, maxPixels / max(w, h))
        let pw = max(1, Int((w * scale).rounded())), ph = max(1, Int((h * scale).rounded()))
        guard let context = ImageIOKit.makeContext(width: pw, height: ph, opaque: true) else { throw LimeError("Lime couldn't draw one of the PDF pages.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw LimeError("Lime couldn't draw one of the PDF pages.") }
        return image
    }

    /// Writes page images; one page → single file, several → a folder.
    static func exportPages(of document: PDFDocument, source: URL, format: String, context: OperationContext, dpi: Double = 300) async throws {
        let options = context.optionsForFormat(format)
        if document.pageCount == 1, let page = document.page(at: 0) {
            try await ImageIOKit.write(try pageImage(page, dpi: dpi), to: context.output(for: source, ext: format), format: format, quality: options.quality)
            return
        }
        let folder = try context.outputFolder(for: source)
        let stem = FormatCatalog.stem(of: source)
        let digits = max(1, String(document.pageCount).count)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw LimeError("Page \(index + 1) of the PDF is unreadable.") }
            let name = "\(stem) \(String(format: "%0\(digits)d", index + 1)).\(format)"
            try await ImageIOKit.write(try pageImage(page, dpi: dpi), to: folder.appendingPathComponent(name), format: format, quality: options.quality)
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
    }
}
