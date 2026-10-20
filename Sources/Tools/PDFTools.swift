import AppKit
import PDFKit
import Quartz

/// PDF compress, split, merge and organize.
enum PDFTools {
    static func compress(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let document = try PDFConverter.open(source)
        let original = ImageTools.fileSize(source)
        let output = context.output(for: source, label: "smaller", ext: "pdf")
        let target = options.targetBytes(original: original)
        // Balanced: the macOS Reduce File Size filter; Strong or a target: re-rasterise pages.
        if target == nil, options.squashLevel == .gentle {
            guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) else {
                throw LimeError("macOS's PDF shrink filter is missing on this Mac.")
            }
            guard document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
                throw LimeError("Lime couldn't write the smaller PDF.")
            }
        } else {
            var dpi = target == nil ? 110.0 : 150.0, quality = target == nil ? 0.55 : 0.7
            for _ in 0..<6 {
                try rasterize(document, to: output, dpi: dpi, quality: quality, context: context)
                guard let target, ImageTools.fileSize(output) > target else { break }
                dpi *= 0.8; quality = max(0.3, quality - 0.1)
                guard dpi >= 40 else { throw LimeError("Lime got it down to \(ByteCountFormatter().string(fromByteCount: Int64(ImageTools.fileSize(output)))) but no smaller.") }
            }
        }
        guard let check = PDFDocument(url: output), check.pageCount == document.pageCount else { throw LimeError("The smaller PDF failed its check.") }
        if ImageTools.fileSize(output) >= original { throw LimeError("Shrinking wouldn't make this file any smaller than it already is.") }
    }

    private static func rasterize(_ document: PDFDocument, to url: URL, dpi: Double, quality: Double, context: OperationContext) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw LimeError("Lime couldn't write the smaller PDF.") }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let image = try DocumentRenderer.pageImage(page, dpi: dpi, maxPixels: 4000)
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality]),
                  let provider = CGDataProvider(data: jpeg as CFData),
                  let decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            let bounds = page.bounds(for: .cropBox)
            var box = page.rotation % 180 == 0 ? CGRect(origin: .zero, size: bounds.size) : CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(decoded, in: box)
            pdf.endPage()
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        pdf.closePDF()
    }

    static func split(_ source: URL, context: OperationContext) throws {
        let document = try PDFConverter.open(source)
        let folder = try context.outputFolder(for: source, label: "pages")
        let stem = FormatCatalog.stem(of: source)
        let digits = max(1, String(document.pageCount).count)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw LimeError("Page \(index + 1) of the PDF is unreadable.") }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let name = "\(stem) \(String(format: "%0\(digits)d", index + 1)).pdf"
            guard single.write(to: folder.appendingPathComponent(name)) else { throw LimeError("Lime couldn't save page \(index + 1).") }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
    }

    static func merge(_ sources: [URL], options: ToolChoices, context: OperationContext) throws {
        let ordered = options.orderedFiles ?? sources
        let merged = PDFDocument()
        for source in ordered {
            let document = try PDFConverter.open(source)
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        guard merged.write(to: context.output(for: ordered[0], label: "combined", ext: "pdf")) else { throw LimeError("Lime couldn't save the combined PDF.") }
    }

    static func organize(_ source: URL, options: ToolChoices, context: OperationContext) throws {
        let document = try PDFConverter.open(source)
        let order = options.pageSequence.isEmpty ? Array(0..<document.pageCount) : options.pageSequence
        guard !order.isEmpty, order.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
            throw LimeError("Every page has to appear once in the new order.")
        }
        let output = PDFDocument()
        var maxWidth: CGFloat = 0
        for (slot, index) in order.enumerated() {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { throw LimeError("Page \(index + 1) of the PDF is unreadable.") }
            let turn = options.pageTurns[slot] ?? 0
            guard turn % 90 == 0 else { throw LimeError("Pages can only turn in steps of 90°.") }
            page.rotation = ((page.rotation + turn) % 360 + 360) % 360
            output.insert(page, at: output.pageCount)
            let b = page.bounds(for: .cropBox)
            maxWidth = max(maxWidth, page.rotation % 180 == 0 ? b.width : b.height)
        }
        if options.matchPageWidths {
            for i in 0..<output.pageCount {
                guard let page = output.page(at: i) else { continue }
                let b = page.bounds(for: .mediaBox)
                let width = page.rotation % 180 == 0 ? b.width : b.height
                guard width > 0, width < maxWidth else { continue }
                let scale = maxWidth / width
                let grown = CGRect(x: b.minX, y: b.minY, width: b.width * scale, height: b.height * scale)
                page.setBounds(grown, for: .mediaBox); page.setBounds(grown, for: .cropBox)
            }
        }
        let url = context.output(for: source, label: "reordered", ext: "pdf")
        guard output.write(to: url), PDFDocument(url: url)?.pageCount == order.count else { throw LimeError("The rearranged PDF failed its check.") }
    }
}
