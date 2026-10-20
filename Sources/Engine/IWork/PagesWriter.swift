import AppKit

/// Writes `.pages` documents without Pages: the body text storage of a
/// bundled template is replaced, reusing the template's own paragraph, list
/// and character styles (Heading 1–3, Body, bullet and numbered lists, bold,
/// italic, bold italic and monospace).
enum PagesWriter {
    struct Failure: Error {}

    /// Style references found in the template's sample paragraphs.
    private struct Styles {
        var heading: [UInt64]          // Heading, Heading 2, Heading 3
        var body: UInt64
        var bulletParagraph: UInt64, numberParagraph: UInt64
        var noList: UInt64, bulletList: UInt64, numberList: UInt64
        var bold: UInt64, italic: UInt64, boldItalic: UInt64, code: UInt64
    }

    private struct Paragraph {
        enum Kind: Equatable { case heading(Int), body, bullet, number }
        var kind: Kind
        var runs: [SemanticDocument.Run]
        var level = 0
    }

    static var template: URL? { Bundle.main.url(forResource: "PagesTemplate", withExtension: "pages") ?? ProcessInfo.processInfo.environment["LIME_PAGES_TEMPLATE"].map(URL.init(fileURLWithPath:)) }

    static func write(_ document: SemanticDocument, to destination: URL, preview: CGImage?, workspace: URL) async throws {
        guard let template else { throw LimeError("The Pages template is missing from the app.") }
        let stage = workspace.appendingPathComponent("pages-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try await ZipPackage.extract(template, to: stage)
        let documentURL = stage.appendingPathComponent("Index/Document.iwa")
        var objects = try IWAFile.read(Data(contentsOf: documentURL))
        guard let index = objects.firstIndex(where: { $0.types.first == 2001 && storageText($0)?.hasPrefix("Heading One") == true }) else {
            throw LimeError("The Pages template is damaged.")
        }
        let storage = try Proto.parse(objects[index].payloads[0])
        let styles = try discoverStyles(storage)
        objects[index].payloads[0] = Proto.encode(rebuild(storage, paragraphs: paragraphs(document), styles: styles))
        try IWAFile.write(objects).write(to: documentURL)
        try resetSelection(stage.appendingPathComponent("Index/ViewState.iwa"))
        try renewIdentity(stage)
        if let preview { try writePreviews(preview, in: stage) }
        try? FileManager.default.removeItem(at: destination)
        let entries = try FileManager.default.subpathsOfDirectory(atPath: stage.path).filter {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: stage.appendingPathComponent($0).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }.sorted()
        // Pages stores every member uncompressed.
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-X0q", destination.path] + entries, directory: stage)
    }

    // MARK: - Template discovery

    private static func storageText(_ object: IWAObject) -> String? {
        guard let fields = try? Proto.parse(object.payloads[0]), let text = fields.first(where: { $0.number == 3 })?.data else { return nil }
        return String(data: text, encoding: .utf8)
    }

    /// `ObjectAttributeTable` entries as (character index, referenced object).
    private static func entries(_ storage: [ProtoField], _ number: Int) -> [(Int, UInt64?)] {
        guard let table = storage.first(where: { $0.number == number })?.fields else { return [] }
        return table.filter { $0.number == 1 }.compactMap(\.fields).map { entry in
            let index = Int(entry.first { $0.number == 1 }?.uint ?? 0)
            let reference = entry.first { $0.number == 2 }?.fields?.first { $0.number == 1 }?.uint
            return (index, reference)
        }
    }

    private static func discoverStyles(_ storage: [ProtoField]) throws -> Styles {
        guard let data = storage.first(where: { $0.number == 3 })?.data, let text = String(data: data, encoding: .utf8) else { throw Failure() }
        let ns = text as NSString
        func offset(_ word: String) throws -> Int {
            let r = ns.range(of: word)
            guard r.location != NSNotFound else { throw Failure() }
            return r.location
        }
        func style(_ table: Int, at index: Int) throws -> UInt64 {
            guard let ref = entries(storage, table).last(where: { $0.0 <= index })?.1 else { throw Failure() }
            return ref
        }
        return Styles(
            heading: [try style(5, at: offset("Heading One")), try style(5, at: offset("Heading Two")), try style(5, at: offset("Heading Three"))],
            body: try style(5, at: offset("Body plain")),
            bulletParagraph: try style(5, at: offset("Bullet item")), numberParagraph: try style(5, at: offset("Numbered item")),
            noList: try style(7, at: offset("Body plain")), bulletList: try style(7, at: offset("Bullet item")), numberList: try style(7, at: offset("Numbered item")),
            bold: try style(8, at: offset("bold")), italic: try style(8, at: offset("italic")),
            boldItalic: try style(8, at: offset("both")), code: try style(8, at: offset("code")))
    }

    // MARK: - Content

    private static func paragraphs(_ document: SemanticDocument) -> [Paragraph] {
        func runs(_ inlines: [SemanticDocument.Inline]) -> [SemanticDocument.Run] {
            inlines.compactMap { if case .run(let r) = $0 { return r }; return nil }
        }
        var result: [Paragraph] = []
        for block in document.blocks {
            switch block {
            case .heading(let level, let inlines): result.append(.init(kind: .heading(min(3, max(1, level))), runs: runs(inlines)))
            case .paragraph(let inlines): result.append(.init(kind: .body, runs: runs(inlines)))
            case .listItem(let ordered, let level, let inlines):
                result.append(.init(kind: ordered ? .number : .bullet, runs: runs(inlines), level: min(8, max(0, level))))
            case .table(let rows):
                for row in rows {
                    var cells: [SemanticDocument.Run] = []
                    for (i, cell) in row.enumerated() {
                        if i > 0 { cells.append(.init(text: "\t")) }
                        cells += runs(cell)
                    }
                    result.append(.init(kind: .body, runs: cells))
                }
            case .rule: break
            }
        }
        return result.isEmpty ? [.init(kind: .body, runs: [])] : result
    }

    /// Paragraph text without characters that would split the paragraph.
    private static func clean(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{2029}", "\u{2028}": out.append(" ")
            case "\u{fffc}": break
            case "\t": out.append("\t")
            default: if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    private static func reference(_ id: UInt64) -> ProtoField { .message(2, [.varint(1, id)]) }

    private static func objectTable(_ number: Int, _ items: [(Int, UInt64?)]) -> ProtoField {
        .message(number, items.map { index, ref in .message(1, [.varint(1, UInt64(index))] + (ref.map { [reference($0)] } ?? [])) })
    }

    private static func dataTable(_ number: Int, _ items: [(Int, UInt64, UInt64)]) -> ProtoField {
        .message(number, items.map { .message(1, [.varint(1, UInt64($0.0)), .varint(2, $0.1), .varint(3, $0.2)]) })
    }

    /// Adds an entry only when the value changes, as Pages does.
    private static func appendChange<T: Equatable>(_ list: inout [(Int, T)], _ index: Int, _ value: T) {
        if let last = list.last, last.1 == value { return }
        list.append((index, value))
    }

    private static func rebuild(_ storage: [ProtoField], paragraphs: [Paragraph], styles: Styles) -> [ProtoField] {
        var text = ""
        var paraStyles: [(Int, UInt64?)] = [], listStyles: [(Int, UInt64?)] = [], charStyles: [(Int, UInt64?)] = []
        // Lists: paragraph data holds (level, starts a list) and the second
        // table the start number, both written at every list paragraph.
        var paraData: [(Int, UInt64, UInt64)] = [], listData: [(Int, UInt64, UInt64)] = []
        var previousKind: Paragraph.Kind?
        for (number, paragraph) in paragraphs.enumerated() {
            let start = (text as NSString).length
            let style: UInt64, list: UInt64, inList: Bool
            switch paragraph.kind {
            case .heading(let level): style = styles.heading[level - 1]; list = styles.noList; inList = false
            case .body: style = styles.body; list = styles.noList; inList = false
            case .bullet: style = styles.bulletParagraph; list = styles.bulletList; inList = true
            case .number: style = styles.numberParagraph; list = styles.numberList; inList = true
            }
            paraStyles.append((start, style))
            appendChange(&listStyles, start, list)
            if inList {
                let starts = previousKind != paragraph.kind
                paraData.append((start, UInt64(paragraph.level), starts ? 1 : 0))
                listData.append((start, starts ? 1 : 0, 0))
            } else if paraData.last.map({ $0.1 != 0 || $0.2 != 0 }) ?? true {
                paraData.append((start, 0, 0))
                listData.append((start, 0, 0))
            }
            previousKind = paragraph.kind
            for run in paragraph.runs {
                let piece = clean(run.text)
                guard !piece.isEmpty else { continue }
                let char: UInt64? = run.code ? styles.code
                    : run.bold && run.italic ? styles.boldItalic : run.bold ? styles.bold : run.italic ? styles.italic : nil
                appendChange(&charStyles, (text as NSString).length, char)
                text += piece
            }
            if number < paragraphs.count - 1 {
                appendChange(&charStyles, (text as NSString).length, nil)
                text += "\n"
            }
        }
        if charStyles.first?.0 != 0 { charStyles.insert((0, nil), at: 0) }
        var result: [ProtoField] = []
        for field in storage {
            switch field.number {
            case 3: result.append(.bytes(3, Data(text.utf8)))
            case 5: result.append(objectTable(5, paraStyles))
            case 6: result.append(dataTable(6, paraData))
            case 7: result.append(objectTable(7, listStyles))
            case 8: result.append(objectTable(8, charStyles))
            case 14: result.append(dataTable(14, listData))
            default: result.append(field)
            }
        }
        return result
    }

    // MARK: - Package

    /// The template was saved with its text selected; start at the top instead.
    private static func resetSelection(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        var objects = try IWAFile.read(data)
        func zeroRanges(_ fields: [ProtoField], depth: Int) -> [ProtoField] {
            fields.map { field in
                guard depth < 8, var inner = field.fields, !inner.isEmpty, field.data?.isEmpty == false else {
                    return depth >= 3 && field.number == 4 && field.uint != nil ? .varint(4, 0) : field
                }
                let isRange = inner.count == 2 && inner.allSatisfy { ($0.number == 1 || $0.number == 2) && $0.uint != nil }
                if isRange { return .message(field.number, [.varint(1, 0), .varint(2, 0)]) }
                inner = zeroRanges(inner, depth: depth + 1)
                return .message(field.number, inner)
            }
        }
        for i in objects.indices where objects[i].types.first == 10131 {
            if let fields = try? Proto.parse(objects[i].payloads[0]) { objects[i].payloads[0] = Proto.encode(zeroRanges(fields, depth: 0)) }
        }
        try IWAFile.write(objects).write(to: url)
    }

    /// Every saved document gets its own identity so Pages does not treat
    /// copies as versions of the template.
    private static func renewIdentity(_ stage: URL) throws {
        let identifier = stage.appendingPathComponent("Metadata/DocumentIdentifier")
        try Data(UUID().uuidString.utf8).write(to: identifier)
        let plistURL = stage.appendingPathComponent("Metadata/Properties.plist")
        guard var plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)) as? [String: Any] else { return }
        let version = UUID().uuidString
        for key in ["documentUUID", "shareUUID", "privateUUID", "stableDocumentUUID"] { plist[key] = UUID().uuidString }
        plist["shareUUID"] = plist["documentUUID"]
        plist["versionUUID"] = version
        plist["revision"] = "0::" + version
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: plistURL)
    }

    private static func writePreviews(_ image: CGImage, in stage: URL) throws {
        for (name, width) in [("preview.jpg", 1024.0), ("preview-web.jpg", 256.0), ("preview-micro.jpg", 64.0)] {
            let scale = min(1, width / Double(image.width))
            let size = CGSize(width: max(1, Double(image.width) * scale), height: max(1, Double(image.height) * scale))
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            guard let scaled = context.makeImage() else { continue }
            try ImageIOKit.writeImageIO(scaled, to: stage.appendingPathComponent(name), format: "jpg", quality: 0.8, metadata: [:])
        }
    }
}
