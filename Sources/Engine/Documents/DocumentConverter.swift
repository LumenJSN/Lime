import AppKit
import PDFKit

/// DOCX, Pages, Markdown, RTF(D), clippings, TXT and EPUB conversions.
enum DocTranscoder {
    static func convert(_ source: URL, from format: String, to target: String, context: OperationContext) async throws {
        let options = context.optionsForFormat(target)
        // Pages → PDF/images keep the document's own layout from Quick Look.
        if format == "pages", ["pdf", "png", "jpg"].contains(target) {
            let pdf = try await QuickLookExport.documentPDF(source, workspace: try context.scratchDirectory())
            context.progress(0.5)
            if target == "pdf" {
                guard pdf.write(to: context.output(for: source, ext: "pdf")) else { throw LimeError("The PDF could not be saved.") }
            } else {
                try await DocumentRenderer.exportPages(of: pdf, source: source, format: target, context: context, dpi: 200)
            }
            return
        }
        let text = try await DocumentReader.read(source, format: format, context: context)
        context.progress(0.4)
        try await write(text, source: source, sourceFormat: format, target: target, options: options, context: context)
    }

    static func write(_ text: NSAttributedString, source: URL, sourceFormat: String, target: String,
                      options: ConvertPrefs, context: OperationContext, titleOverride: String? = nil) async throws {
        let title = titleOverride ?? FormatCatalog.stem(of: source)
        switch target {
        case "txt":
            var string = text.string.replacingOccurrences(of: "\u{fffc}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
            if !string.hasSuffix("\n") { string += "\n" }
            try string.write(to: context.output(for: source, ext: "txt"), atomically: true, encoding: .utf8)
        case "md":
            if sourceFormat == "txt" {
                try DocumentReader.readText(source).write(to: context.output(for: source, ext: "md"), atomically: true, encoding: .utf8)
            } else {
                try DocumentSerializer.markdown(SemanticDocument.from(text)).write(to: context.output(for: source, ext: "md"), atomically: true, encoding: .utf8)
            }
        case "html":
            let html: String
            if sourceFormat == "md" {
                html = MarkdownRenderer.html(from: try DocumentReader.readText(source))
                    .replacingOccurrences(of: "<head><meta charset=\"utf-8\"></head>", with: "<head><meta charset=\"utf-8\"><title>\(HTMLEscape.text(title))</title></head>")
            } else {
                html = DocumentSerializer.html(SemanticDocument.from(text), title: title)
            }
            try html.write(to: context.output(for: source, ext: "html"), atomically: true, encoding: .utf8)
        case "docx":
            try await writeDOCX(text, sourceFormat: sourceFormat, title: title, to: context.output(for: source, ext: "docx"), context: context)
        case "pages":
            // Native Pages document; the first page also becomes its Finder preview.
            let pdfURL = context.scratch("pdf")
            try DocumentRenderer.renderPDF(text, to: pdfURL)
            let preview = PDFDocument(url: pdfURL)?.page(at: 0).flatMap { try? DocumentRenderer.pageImage($0, dpi: 110) }
            try await PagesWriter.write(SemanticDocument.from(text), to: context.output(for: source, ext: "pages"), preview: preview, workspace: context.workspace)
        case "epub":
            try await EPUBWriter.write(SemanticDocument.from(text), title: title, to: context.output(for: source, ext: "epub"), workspace: context.workspace)
        case "pdf":
            try DocumentRenderer.renderPDF(text, to: context.output(for: source, ext: "pdf"))
        case "png", "jpg":
            let pdfURL = context.scratch("pdf")
            try DocumentRenderer.renderPDF(text, to: pdfURL)
            guard let pdf = PDFDocument(url: pdfURL) else { throw LimeError("The finished PDF failed its check.") }
            try await DocumentRenderer.exportPages(of: pdf, source: source, format: target, context: context, dpi: 200)
        default:
            throw LimeError("Lime can't turn \(FormatCatalog.label(sourceFormat)) into \(FormatCatalog.label(target)).")
        }
        _ = options
    }

    /// Structured sources get real Word styles; rich text keeps its fonts and colours.
    static func writeDOCX(_ text: NSAttributedString, sourceFormat: String, title: String, to url: URL, context: OperationContext) async throws {
        if ["md", "txt", "epub", "pdf", "html"].contains(sourceFormat) {
            try await DOCXWriter.write(SemanticDocument.from(text), title: title, to: url, workspace: context.workspace)
        } else {
            try writeDOCX(text, to: url)
        }
    }

    static func writeDOCX(_ text: NSAttributedString, to url: URL) throws {
        let normalized = DocumentRenderer.withDefaults(text)
        let data = try normalized.data(from: NSRange(location: 0, length: normalized.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
    }
}

/// SRT ↔ VTT with cue timing preserved, plus text extraction.
enum CaptionTranscoder {
    static func convert(_ source: URL, to format: String, context: OperationContext) throws {
        guard let raw = try? String(contentsOf: source, encoding: .utf8) else { throw LimeError("The subtitles aren't saved as UTF-8 text.") }
        let text = raw.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let pattern = #"(?m)^(?:(\d{1,}):)?(\d{2}):(\d{2})[.,](\d{3})[ \t]+-->[ \t]+(?:(\d{1,}):)?(\d{2}):(\d{2})[.,](\d{3})([^\n]*)\n([\s\S]*?)(?=\n\n|\n*\z)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { throw LimeError("The subtitle file has no usable lines.") }
        var cues: [String] = []
        for (index, match) in matches.enumerated() {
            func field(_ n: Int, _ fallback: String = "00") -> String {
                match.range(at: n).location == NSNotFound ? fallback : ns.substring(with: match.range(at: n))
            }
            let body = field(10, "").trimmingCharacters(in: .newlines)
            if format == "txt" {
                let stripped = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !stripped.isEmpty { cues.append(stripped) }
                continue
            }
            let separator = format == "vtt" ? "." : ","
            func hours(_ n: Int) -> String { let h = field(n); return h.count < 2 ? "0" + h : h }
            let start = "\(hours(1)):\(field(2)):\(field(3))\(separator)\(field(4))"
            let end = "\(hours(5)):\(field(6)):\(field(7))\(separator)\(field(8))"
            let settings = format == "vtt" ? field(9, "") : ""
            cues.append((format == "srt" ? "\(index + 1)\n" : "") + start + " --> " + end + settings + "\n" + body)
        }
        let output = (format == "vtt" ? "WEBVTT\n\n" : "") + cues.joined(separator: format == "txt" ? "\n" : "\n\n") + "\n"
        try output.write(to: context.output(for: source, ext: format), atomically: true, encoding: .utf8)
    }
}
