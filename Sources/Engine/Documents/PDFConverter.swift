import AppKit
import PDFKit
import Vision

/// PDF → DOCX, Pages, PPTX, XLSX, JPG, PNG, EPUB, TXT and Markdown.
enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw LimeError("This PDF is unreadable or locked.") }
        guard !document.isLocked else { throw LimeError("This PDF is unreadable or locked.") }
        guard document.pageCount > 0 else { throw LimeError("This PDF is blank.") }
        return document
    }

    static func convert(_ source: URL, to target: String, context: OperationContext) async throws {
        let document = try open(source)
        let options = context.optionsForFormat(target)
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? FormatCatalog.stem(of: source)
        switch target {
        case "jpg", "png":
            try await DocumentRenderer.exportPages(of: document, source: source, format: target, context: context)
        case "txt":
            let text = try await pageTexts(document, context: context).joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LimeError("This PDF has no text or drawings Lime can pull out.") }
            try text.write(to: context.output(for: source, ext: "txt"), atomically: true, encoding: .utf8)
        case "md":
            let attributed = try await attributedText(document, context: context)
            try DocumentSerializer.markdown(SemanticDocument.from(attributed)).write(to: context.output(for: source, ext: "md"), atomically: true, encoding: .utf8)
        case "docx", "pages":
            let attributed = options.pdfDocMode == "pages" ? try pageImagesAttributed(document) : try await attributedText(document, context: context)
            try await DocTranscoder.write(attributed, source: source, sourceFormat: "pdf", target: target, options: options, context: context, titleOverride: title)
        case "epub":
            if options.epubMode == "fixed" {
                let size = document.page(at: 0)?.bounds(for: .cropBox).size ?? DocumentRenderer.defaultPageSize
                let pages = try jpegPages(document, dpi: 150, context: context)
                try await EPUBWriter.writeFixed(pages: pages, pageSize: size, title: title, to: context.output(for: source, ext: "epub"), workspace: context.workspace)
            } else {
                let attributed = try await attributedText(document, context: context)
                try await EPUBWriter.write(SemanticDocument.from(attributed), title: title, to: context.output(for: source, ext: "epub"), workspace: context.workspace)
            }
        case "pptx":
            let size = document.page(at: 0)?.bounds(for: .cropBox).size ?? CGSize(width: 960, height: 540)
            let slides = try jpegPages(document, dpi: 200, context: context)
            try await PPTXWriter.write(slides: slides, size: size, to: context.output(for: source, ext: "pptx"), workspace: context.workspace)
        case "xlsx":
            var sheets: [Workbook.Sheet] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let rows = try await tableRows(page)
                sheets.append(.init(name: "Page \(index + 1)", rows: rows))
                context.progress(Double(index + 1) / Double(document.pageCount) * 0.9)
            }
            guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw LimeError("This PDF has no text or drawings Lime can pull out.") }
            try await XLSX.write(Workbook(sheets: sheets), to: context.output(for: source, ext: "xlsx"), workspace: context.workspace)
        default:
            throw LimeError("Lime can't turn a PDF into \(FormatCatalog.label(target)).")
        }
    }

    // MARK: - Text

    static func pageTexts(_ document: PDFDocument, context: OperationContext?) async throws -> [String] {
        var result: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw LimeError("Page \(index + 1) of the PDF is unreadable.") }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(text.isEmpty ? try ocrLines(page).map(\.text).joined(separator: "\n") : text)
            context?.progress(Double(index + 1) / Double(document.pageCount) * 0.8)
        }
        return result
    }

    static func attributedText(_ document: PDFDocument, context: OperationContext?) async throws -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw LimeError("Page \(index + 1) of the PDF is unreadable.") }
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            if let text = page.attributedString, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(reflow(text))
            } else {
                let lines = try ocrLines(page).map(\.text)
                result.append(DocumentReader.plain(lines.joined(separator: "\n")))
            }
            context?.progress(Double(index + 1) / Double(document.pageCount) * 0.8)
        }
        guard result.length > 0 else { throw LimeError("This PDF has no text or drawings Lime can pull out.") }
        return result
    }

    /// Joins hard-wrapped lines inside paragraphs while keeping headings.
    static func reflow(_ text: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = text.string.components(separatedBy: "\n")
        var location = 0
        for (i, line) in lines.enumerated() {
            let range = NSRange(location: location, length: (line as NSString).length)
            location += range.length + 1
            let piece = range.length > 0 ? text.attributedSubstring(from: range) : NSAttributedString(string: "")
            output.append(piece)
            guard i < lines.count - 1 else { break }
            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
            let current = line.trimmingCharacters(in: .whitespaces)
            let sameSize = range.length > 0 && location < text.length
                && ((text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0)
                    == ((text.attribute(.font, at: min(text.length - 1, location), effectiveRange: nil) as? NSFont)?.pointSize ?? 0)
            let joins = !current.isEmpty && !next.isEmpty && sameSize && !current.hasSuffix(".") && !current.hasSuffix(":")
                && next.first.map { $0.isLowercase } == true
            output.append(NSAttributedString(string: joins ? " " : "\n"))
        }
        return output
    }

    struct OCRLine { let text: String; let box: CGRect }

    /// Local Vision text recognition on a 300 DPI render.
    static func ocrLines(_ page: PDFPage) throws -> [OCRLine] {
        let image = try DocumentRenderer.pageImage(page, dpi: 300, maxPixels: 6000)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { throw LimeError("OCR failed on a scanned page: \(error.localizedDescription)") }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, box: observation.boundingBox)
        }.sorted { abs($0.box.midY - $1.box.midY) > 0.008 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
    }

    // MARK: - Pages as images

    static func jpegPages(_ document: PDFDocument, dpi: Double, context: OperationContext) throws -> [Data] {
        var pages: [Data] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw LimeError("Page \(index + 1) of the PDF is unreadable.") }
            let image = try DocumentRenderer.pageImage(page, dpi: dpi, maxPixels: 4096)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { throw LimeError("Lime couldn't turn the page into a picture.") }
            pages.append(data)
            context.progress(Double(index + 1) / Double(document.pageCount) * 0.85)
        }
        return pages
    }

    static func pageImagesAttributed(_ document: PDFDocument) throws -> NSAttributedString {
        let result = NSMutableAttributedString()
        let width = DocumentRenderer.defaultPageSize.width - 108
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let image = try DocumentRenderer.pageImage(page, dpi: 150)
            let attachment = NSTextAttachment()
            attachment.image = NSImage(cgImage: image, size: .zero)
            let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
            result.append(NSAttributedString(attachment: attachment))
            if index < document.pageCount - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    // MARK: - Tables

    /// Groups characters into lines, then splits cells at wide gaps.
    static func tableRows(_ page: PDFPage) async throws -> [[String]] {
        guard let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let lines = try ocrLines(page)
            var rows: [[String]] = []
            var currentY: CGFloat?
            for line in lines {
                if let y = currentY, abs(y - line.box.midY) < 0.01 { rows[rows.count - 1].append(line.text) }
                else { rows.append([line.text]); currentY = line.box.midY }
            }
            return rows
        }
        let ns = string as NSString
        struct Glyph { let char: String; let rect: CGRect }
        var lines: [[Glyph]] = []
        var lastY: CGFloat = .infinity
        for i in 0..<ns.length {
            let char = ns.substring(with: NSRange(location: i, length: 1))
            if char == "\n" || char == "\r" { lastY = .infinity; continue }
            let rect = page.characterBounds(at: i)
            guard rect.width > 0 || char == " " else { continue }
            if lines.isEmpty || abs(rect.midY - lastY) > max(2, rect.height * 0.5) { lines.append([]); lastY = rect.midY }
            lines[lines.count - 1].append(Glyph(char: char, rect: rect))
        }
        return lines.map { glyphs in
            let sorted = glyphs.sorted { $0.rect.minX < $1.rect.minX }
            let widths = sorted.filter { $0.char != " " }.map(\.rect.width)
            let average = widths.isEmpty ? 5 : widths.reduce(0, +) / CGFloat(widths.count)
            var cells: [String] = [], cell = ""
            var previousMaxX: CGFloat?
            for glyph in sorted {
                if let p = previousMaxX, glyph.rect.minX - p > average * 1.8, glyph.char != " " {
                    cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
                }
                cell += glyph.char
                if glyph.char != " " { previousMaxX = glyph.rect.maxX }
            }
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            return cells
        }.filter { !$0.allSatisfy(\.isEmpty) }
    }
}
