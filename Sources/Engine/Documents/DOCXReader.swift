import AppKit

/// Reads WordprocessingML with its styles, numbering, tables, links and
/// images into rich text (AppKit's importer ignores paragraph styles).
enum DOCXReader {
    private struct Style { var heading: Int?; var bold: Bool?; var italic: Bool?; var size: CGFloat?; var basedOn: String? }

    static func read(_ url: URL, workspace: URL) async throws -> NSAttributedString {
        let root = workspace.appendingPathComponent("docx-" + UUID().uuidString, isDirectory: true)
        try await ZipPackage.extract(url, to: root)
        let documentURL = root.appendingPathComponent("word/document.xml")
        guard let document = try? XMLDocument(contentsOf: documentURL, options: []) else { throw LimeError("Lime couldn't open the file.") }
        let styles = loadStyles(root)
        let numbering = loadNumbering(root)
        let rels = loadRelationships(root.appendingPathComponent("word/_rels/document.xml.rels"))
        let defaultSize = styles.defaultSize
        let output = NSMutableAttributedString()
        guard let body = try document.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else { throw LimeError("This document is blank.") }
        var listCounters: [String: Int] = [:]

        func resolved(_ id: String?) -> Style {
            var result = Style(), current = id, depth = 0
            while let key = current, let s = styles.map[key], depth < 10 {
                if result.heading == nil { result.heading = s.heading }
                if result.bold == nil { result.bold = s.bold }
                if result.italic == nil { result.italic = s.italic }
                if result.size == nil { result.size = s.size }
                current = s.basedOn; depth += 1
            }
            return result
        }

        func paragraph(_ p: XMLElement, block: NSTextTableBlock? = nil) {
            let pPr = p.child("pPr")
            let styleID = pPr?.child("pStyle")?.attr("val")
            let style = resolved(styleID)
            var heading = style.heading
            if let level = pPr?.child("outlineLvl")?.attr("val").flatMap(Int.init), level < 6 { heading = level + 1 }
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = 6
            var prefix = ""
            if let numPr = pPr?.child("numPr"), let numID = numPr.child("numId")?.attr("val"), numID != "0" {
                let level = Int(numPr.child("ilvl")?.attr("val") ?? "0") ?? 0
                let ordered = numbering[numID]?[level] ?? false
                let key = "\(numID)-\(level)"
                listCounters[key, default: 0] += 1
                let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
                paragraphStyle.textLists = Array(repeating: list, count: level + 1)
                paragraphStyle.headIndent = CGFloat(36 + level * 18)
                prefix = "\t" + (ordered ? "\(listCounters[key]!)." : "•") + "\t"
            }
            if let block { paragraphStyle.textBlocks = [block] }
            if let jc = pPr?.child("jc")?.attr("val") {
                paragraphStyle.alignment = jc == "center" ? .center : jc == "right" || jc == "end" ? .right : jc == "both" ? .justified : .left
            }
            let baseSize: CGFloat = style.size ?? (heading.map { [0, 20, 16, 13, 12, 11, 11][min(6, $0)] } ?? defaultSize)
            let line = NSMutableAttributedString()
            if !prefix.isEmpty { line.append(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: baseSize)])) }
            func appendRun(_ r: XMLElement, link: URL?) {
                let rPr = r.child("rPr")
                let bold = rPr?.flag("b") ?? style.bold ?? (heading != nil)
                let italic = rPr?.flag("i") ?? style.italic ?? false
                let size = rPr?.child("sz")?.attr("val").flatMap(Double.init).map { CGFloat($0) / 2 } ?? baseSize
                var font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
                if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if let mono = rPr?.child("rFonts")?.attr("ascii"), ["Menlo", "Courier", "Courier New", "Consolas", "Monaco"].contains(mono) {
                    font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: NSColor.black]
                if let u = rPr?.child("u")?.attr("val"), u != "none" { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if rPr?.flag("strike") == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link { attributes[.link] = link }
                for child in r.children ?? [] {
                    guard let e = child as? XMLElement else { continue }
                    switch e.localName {
                    case "t": line.append(NSAttributedString(string: e.stringValue ?? "", attributes: attributes))
                    case "tab": line.append(NSAttributedString(string: "\t", attributes: attributes))
                    case "br", "cr": line.append(NSAttributedString(string: "\u{2028}", attributes: attributes))
                    case "drawing", "pict":
                        let embed = (try? e.nodes(forXPath: ".//*[local-name()='blip']"))?.compactMap { ($0 as? XMLElement)?.attributes?.first { $0.localName == "embed" }?.stringValue }.first
                        if let embed, let target = rels[embed], let image = NSImage(contentsOf: root.appendingPathComponent("word").appendingPathComponent(target)) {
                            let attachment = NSTextAttachment()
                            attachment.image = image
                            if let extent = (try? e.nodes(forXPath: ".//*[local-name()='extent']"))?.first as? XMLElement,
                               let cx = Double(extent.attr("cx") ?? ""), let cy = Double(extent.attr("cy") ?? "") {
                                attachment.bounds = CGRect(x: 0, y: 0, width: cx / 12_700, height: cy / 12_700)
                            }
                            line.append(NSAttributedString(attachment: attachment))
                        }
                    default: break
                    }
                }
            }
            for child in p.children ?? [] {
                guard let e = child as? XMLElement else { continue }
                if e.localName == "r" { appendRun(e, link: nil) }
                else if e.localName == "hyperlink" {
                    let link = e.attributes?.first { $0.localName == "id" }?.stringValue.flatMap { rels[$0] }.flatMap(URL.init(string:))
                    for r in (e.children ?? []).compactMap({ $0 as? XMLElement }) where r.localName == "r" { appendRun(r, link: link) }
                } else if ["ins", "smartTag", "sdt", "fldSimple"].contains(e.localName ?? "") {
                    for r in (try? e.nodes(forXPath: ".//*[local-name()='r']")) ?? [] { if let r = r as? XMLElement { appendRun(r, link: nil) } }
                }
            }
            line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraphStyle, .font: NSFont.systemFont(ofSize: baseSize)]))
            output.append(line)
        }

        func walk(_ element: XMLElement) throws {
            for child in element.children ?? [] {
                try Task.checkCancellation()
                guard let e = child as? XMLElement else { continue }
                switch e.localName {
                case "p": paragraph(e)
                case "tbl":
                    let rows = e.children?.compactMap { ($0 as? XMLElement)?.localName == "tr" ? $0 as? XMLElement : nil } ?? []
                    let columns = rows.map { $0.children?.filter { ($0 as? XMLElement)?.localName == "tc" }.count ?? 0 }.max() ?? 1
                    guard columns > 0, columns < 64 else { continue }
                    let table = NSTextTable()
                    table.numberOfColumns = columns
                    table.collapsesBorders = true
                    for (r, row) in rows.enumerated() {
                        let cells = row.children?.compactMap { ($0 as? XMLElement)?.localName == "tc" ? $0 as? XMLElement : nil } ?? []
                        for (c, cell) in cells.enumerated() {
                            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                            block.setWidth(0.5, type: .absoluteValueType, for: .border)
                            block.setBorderColor(.gray)
                            block.setWidth(4, type: .absoluteValueType, for: .padding)
                            let paragraphs = cell.children?.compactMap { ($0 as? XMLElement)?.localName == "p" ? $0 as? XMLElement : nil } ?? []
                            if paragraphs.isEmpty {
                                let style = NSMutableParagraphStyle(); style.textBlocks = [block]
                                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
                            }
                            for p in paragraphs { paragraph(p, block: block) }
                        }
                    }
                case "sdt", "sdtContent", "customXml": try walk(e)
                default: break
                }
            }
        }
        try walk(body)
        guard output.length > 0 else { throw LimeError("This document is blank.") }
        return output
    }

    private static func loadStyles(_ root: URL) -> (map: [String: Style], defaultSize: CGFloat) {
        guard let doc = try? XMLDocument(contentsOf: root.appendingPathComponent("word/styles.xml"), options: []) else { return ([:], 11) }
        var map: [String: Style] = [:]
        var defaultSize: CGFloat = 11
        if let sz = (try? doc.nodes(forXPath: "//*[local-name()='rPrDefault']//*[local-name()='sz']"))?.first as? XMLElement, let v = Double(sz.attr("val") ?? "") { defaultSize = CGFloat(v / 2) }
        for node in (try? doc.nodes(forXPath: "//*[local-name()='style']")) ?? [] {
            guard let e = node as? XMLElement, let id = e.attr("styleId") else { continue }
            var s = Style()
            let name = e.child("name")?.attr("val")?.lowercased() ?? ""
            if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)) { s.heading = n }
            else if name == "title" { s.heading = 1 }
            if let level = e.child("pPr")?.child("outlineLvl")?.attr("val").flatMap(Int.init), level < 6 { s.heading = level + 1 }
            let rPr = e.child("rPr")
            s.bold = rPr?.flag("b"); s.italic = rPr?.flag("i")
            if let v = rPr?.child("sz")?.attr("val").flatMap(Double.init) { s.size = CGFloat(v / 2) }
            s.basedOn = e.child("basedOn")?.attr("val")
            map[id] = s
        }
        return (map, defaultSize)
    }

    /// numId → level → ordered?
    private static func loadNumbering(_ root: URL) -> [String: [Int: Bool]] {
        guard let doc = try? XMLDocument(contentsOf: root.appendingPathComponent("word/numbering.xml"), options: []) else { return [:] }
        var abstracts: [String: [Int: Bool]] = [:]
        for node in (try? doc.nodes(forXPath: "//*[local-name()='abstractNum']")) ?? [] {
            guard let e = node as? XMLElement, let id = e.attr("abstractNumId") else { continue }
            var levels: [Int: Bool] = [:]
            for lvl in e.children?.compactMap({ ($0 as? XMLElement)?.localName == "lvl" ? $0 as? XMLElement : nil }) ?? [] {
                let level = Int(lvl.attr("ilvl") ?? "0") ?? 0
                levels[level] = (lvl.child("numFmt")?.attr("val") ?? "bullet") != "bullet"
            }
            abstracts[id] = levels
        }
        var result: [String: [Int: Bool]] = [:]
        for node in (try? doc.nodes(forXPath: "//*[local-name()='num']")) ?? [] {
            guard let e = node as? XMLElement, let id = e.attr("numId"), let abstract = e.child("abstractNumId")?.attr("val") else { continue }
            result[id] = abstracts[abstract] ?? [:]
        }
        return result
    }

    private static func loadRelationships(_ url: URL) -> [String: String] {
        guard let doc = try? XMLDocument(contentsOf: url, options: []) else { return [:] }
        var map: [String: String] = [:]
        for node in (try? doc.nodes(forXPath: "//*[local-name()='Relationship']")) ?? [] {
            guard let e = node as? XMLElement, let id = e.attr("Id"), let target = e.attr("Target") else { continue }
            if target.contains("..") && e.attr("TargetMode") != "External" { continue }
            map[id] = target
        }
        return map
    }
}

private extension XMLElement {
    func child(_ name: String) -> XMLElement? {
        children?.first { ($0 as? XMLElement)?.localName == name } as? XMLElement
    }
    func attr(_ name: String) -> String? {
        attributes?.first { $0.localName == name }?.stringValue
    }
    /// OOXML on/off property: present without val, or val not false/0.
    func flag(_ name: String) -> Bool? {
        guard let e = child(name) else { return nil }
        let v = e.attr("val")
        return v == nil || !["0", "false", "off", "none"].contains(v!)
    }
}
