import AppKit

/// Structured view of rich text used by the HTML, Markdown and EPUB writers.
struct SemanticDocument {
    struct Run { var text: String; var bold = false; var italic = false; var underline = false; var strike = false; var link: String? = nil; var code = false }
    struct Image { let data: Data; let ext: String; let width: CGFloat; let height: CGFloat }
    enum Inline { case run(Run), image(Image) }
    enum Block {
        case heading(Int, [Inline])
        case paragraph([Inline])
        case listItem(ordered: Bool, level: Int, [Inline])
        case table([[[Inline]]])
        case rule
    }
    var blocks: [Block] = []
    var title: String?

    // MARK: - Extraction

    static func from(_ text: NSAttributedString) -> SemanticDocument {
        var document = SemanticDocument()
        let string = text.string as NSString
        let bodySize = dominantFontSize(text)
        var tableRows: [[[Inline]]] = []
        var currentTable: NSTextTable?
        var rowCells: [[Inline]] = []
        var lastRow = -1
        var lastBlock: NSTextTableBlock?
        func flushTable() {
            if !rowCells.isEmpty { tableRows.append(rowCells); rowCells = [] }
            if !tableRows.isEmpty { document.blocks.append(.table(tableRows)) }
            tableRows = []; currentTable = nil; lastRow = -1; lastBlock = nil
        }
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs]) { _, range, _, _ in
            let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : (range.location < text.length ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil)
            if let block = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if currentTable !== block.table { flushTable(); currentTable = block.table }
                if block.startingRow != lastRow {
                    if !rowCells.isEmpty { tableRows.append(rowCells) }
                    rowCells = []; lastRow = block.startingRow
                }
                let content = inlines(text, range: range)
                if block === lastBlock, !rowCells.isEmpty {
                    rowCells[rowCells.count - 1] += [.run(Run(text: "\n"))] + content
                } else { rowCells.append(content) }
                lastBlock = block
                return
            }
            if currentTable != nil { flushTable() }
            var paragraph = inlines(text, range: range)
            let raw = string.substring(with: range)
            let plain = raw.trimmingCharacters(in: .whitespaces)
            let leading = raw.count - raw.drop(while: { $0 == " " || $0 == "\t" }).count
            if plain.isEmpty, !paragraph.contains(where: { if case .image = $0 { return true }; return false }) { return }
            if let lists = style?.textLists, let list = lists.last {
                paragraph = stripListMarker(paragraph)
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha") || list.markerFormat.rawValue.contains("roman")
                document.blocks.append(.listItem(ordered: ordered, level: max(0, lists.count - 1), paragraph))
                return
            }
            if let bullet = bulletPrefix(plain) {
                document.blocks.append(.listItem(ordered: bullet, level: 0, stripLeading(paragraph, count: leading + prefixLength(plain))))
                return
            }
            let size = maxFontSize(text, range: range)
            let ratio = bodySize > 0 ? size / bodySize : 1
            if plain.count < 140, ratio >= 1.15 {
                let level = ratio >= 1.75 ? 1 : ratio >= 1.4 ? 2 : ratio >= 1.15 ? 3 : 4
                document.blocks.append(.heading(level, paragraph.map(unbold)))
                if document.title == nil, level <= 2 { document.title = plain }
                return
            }
            document.blocks.append(.paragraph(paragraph))
        }
        if currentTable != nil { flushTable() }
        return document
    }

    private static func dominantFontSize(_ text: NSAttributedString) -> CGFloat {
        var histogram: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { histogram[font.pointSize.rounded(), default: 0] += range.length }
        }
        return histogram.max(by: { $0.value < $1.value })?.key ?? 12
    }
    private static func maxFontSize(_ text: NSAttributedString, range: NSRange) -> CGFloat {
        var size: CGFloat = 0
        text.enumerateAttribute(.font, in: range) { value, _, _ in size = max(size, (value as? NSFont)?.pointSize ?? 0) }
        return size
    }
    private static func isAllBold(_ inlines: [Inline]) -> Bool {
        let runs = inlines.compactMap { if case .run(let r) = $0, !r.text.trimmingCharacters(in: .whitespaces).isEmpty { return r }; return nil }
        return !runs.isEmpty && runs.allSatisfy(\.bold)
    }
    private static func unbold(_ inline: Inline) -> Inline {
        if case .run(var run) = inline { run.bold = false; return .run(run) }
        return inline
    }
    private static func bulletPrefix(_ text: String) -> Bool? {
        if text.range(of: #"^[•◦▪‣·\-*][ \t]"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^\d{1,3}[.)][ \t]"#, options: .regularExpression) != nil { return true }
        return nil
    }
    private static func prefixLength(_ text: String) -> Int {
        if let match = text.range(of: #"^(\d{1,3}[.)]|[•◦▪‣·\-*])[ \t]+"#, options: .regularExpression) { return text.distance(from: text.startIndex, to: match.upperBound) }
        return 0
    }
    private static func stripListMarker(_ inlines: [Inline]) -> [Inline] {
        guard case .run(var first)? = inlines.first else { return inlines }
        if let match = first.text.range(of: #"^\t?[^\t]{0,8}\t"#, options: .regularExpression) {
            first.text.removeSubrange(match)
            return [.run(first)] + inlines.dropFirst()
        }
        return inlines
    }
    private static func stripLeading(_ inlines: [Inline], count: Int) -> [Inline] {
        var remaining = count
        var result: [Inline] = []
        for inline in inlines {
            if remaining > 0, case .run(var run) = inline {
                let drop = min(remaining, run.text.count)
                run.text = String(run.text.dropFirst(drop)); remaining -= drop
                if !run.text.isEmpty { result.append(.run(run)) }
            } else { result.append(inline) }
        }
        return result
    }

    static func inlines(_ text: NSAttributedString, range: NSRange) -> [Inline] {
        var result: [Inline] = []
        guard range.length > 0 else { return result }
        text.enumerateAttributes(in: range) { attributes, sub, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let image = imageData(attachment) { result.append(.image(image)) }
                return
            }
            var piece = (text.string as NSString).substring(with: sub)
            piece = piece.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{fffc}", with: "")
            guard !piece.isEmpty else { return }
            var run = Run(text: piece)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                run.bold = traits.contains(.bold)
                run.italic = traits.contains(.italic)
                run.code = traits.contains(.monoSpace)
            }
            run.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0 && attributes[.link] == nil
            run.strike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            if let link = attributes[.link] { run.link = (link as? URL)?.absoluteString ?? (link as? String) }
            result.append(.run(run))
        }
        return result
    }

    private static func imageData(_ attachment: NSTextAttachment) -> Image? {
        var image: NSImage? = attachment.image
        if image == nil, let data = attachment.fileWrapper?.regularFileContents { image = NSImage(data: data) }
        if image == nil, let data = attachment.contents { image = NSImage(data: data) }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return Image(data: png, ext: "png", width: image.size.width, height: image.size.height)
    }

    var plainText: String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let i), .paragraph(let i): return Self.text(i)
            case .listItem(let ordered, let level, let i): return String(repeating: "  ", count: level) + (ordered ? "• " : "• ") + Self.text(i)
            case .table(let rows): return rows.map { $0.map(Self.text).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: return "———"
            }
        }.joined(separator: "\n\n")
    }

    static func text(_ inlines: [Inline]) -> String {
        inlines.map { if case .run(let r) = $0 { return r.text }; return "" }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
