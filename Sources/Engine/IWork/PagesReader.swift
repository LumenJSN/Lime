import AppKit

/// Reads the body text of a `.pages` document straight from its IWA archives:
/// paragraph order, font sizes, bold/italic and list levels survive, so the
/// usual heading and list detection works on the result.
enum PagesReader {
    private struct CharProps {
        var bold: Bool?, italic: Bool?, size: CGFloat?, font: String?
        mutating func merge(_ other: CharProps) {
            bold = other.bold ?? bold; italic = other.italic ?? italic
            size = other.size ?? size; font = other.font ?? font
        }
    }

    private struct Style { var parent: UInt64?; var chars: CharProps; var listLabels: [UInt64] }

    static func read(_ url: URL, workspace: URL) async throws -> NSAttributedString {
        let index = try await indexFolder(url, workspace: workspace)
        let documentObjects = try IWAFile.read(Data(contentsOf: index.appendingPathComponent("Document.iwa")))
        let sheet = index.appendingPathComponent("DocumentStylesheet.iwa")
        let styleObjects = (try? IWAFile.read(Data(contentsOf: sheet))) ?? []
        var styles: [UInt64: Style] = [:]
        for object in styleObjects + documentObjects {
            guard let type = object.types.first, [2021, 2022, 2023].contains(type), let fields = try? Proto.parse(object.payloads[0]) else { continue }
            styles[object.identifier] = style(fields)
        }
        let storages = documentObjects.filter { $0.types.first == 2001 }.compactMap { object -> [ProtoField]? in
            guard let fields = try? Proto.parse(object.payloads[0]) else { return nil }
            return (fields.first { $0.number == 1 }?.uint ?? 0) == 0 ? fields : nil
        }
        guard let body = storages.max(by: { text($0).count < text($1).count }), !text(body).isEmpty else {
            throw LimeError("The Pages document has no body text.")
        }
        return attributed(body, styles: styles)
    }

    /// The `Index` folder of a single-file or package document.
    private static func indexFolder(_ url: URL, workspace: URL) async throws -> URL {
        let stage = workspace.appendingPathComponent("pages-read-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let indexZip = url.appendingPathComponent("Index.zip")
            if FileManager.default.fileExists(atPath: indexZip.path) {
                try await ZipPackage.extract(indexZip, to: stage)
                return stage.appendingPathComponent("Index")
            }
            return url.appendingPathComponent("Index")
        }
        try await ZipPackage.extract(url, to: stage)
        return stage.appendingPathComponent("Index")
    }

    private static func text(_ storage: [ProtoField]) -> String {
        storage.first { $0.number == 3 }?.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func style(_ fields: [ProtoField]) -> Style {
        let parent = fields.first { $0.number == 1 }?.fields?.first { $0.number == 3 }?.fields?.first { $0.number == 1 }?.uint
        var chars = CharProps()
        if let props = fields.first(where: { $0.number == 11 })?.fields {
            for field in props {
                switch (field.number, field.value) {
                case (1, .varint(let v)): chars.bold = v != 0
                case (2, .varint(let v)): chars.italic = v != 0
                case (3, .fixed32(let d)): chars.size = CGFloat(Float(bitPattern: d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                case (5, .bytes(let d)): chars.font = String(data: d, encoding: .utf8)
                default: break
                }
            }
        }
        let labels = fields.filter { $0.number == 11 }.compactMap(\.uint)
        return Style(parent: parent, chars: chars, listLabels: labels)
    }

    private static func resolved(_ id: UInt64?, in styles: [UInt64: Style]) -> CharProps {
        var chain: [CharProps] = [], current = id, guardCount = 0
        while let ref = current, let style = styles[ref], guardCount < 32 {
            chain.append(style.chars); current = style.parent; guardCount += 1
        }
        var props = CharProps()
        chain.reversed().forEach { props.merge($0) }
        return props
    }

    private static func table(_ storage: [ProtoField], _ number: Int) -> [(Int, [ProtoField])] {
        (storage.first { $0.number == number }?.fields ?? []).filter { $0.number == 1 }.compactMap(\.fields).map {
            (Int($0.first { $0.number == 1 }?.uint ?? 0), $0)
        }
    }

    private static func reference(_ entry: [ProtoField]) -> UInt64? {
        entry.first { $0.number == 2 }?.fields?.first { $0.number == 1 }?.uint
    }

    private static func value<T>(at index: Int, in table: [(Int, T)]) -> T? { table.last { $0.0 <= index }?.1 }

    private static func attributed(_ storage: [ProtoField], styles: [UInt64: Style]) -> NSAttributedString {
        let raw = text(storage) as NSString
        let paraStyles = table(storage, 5).map { ($0.0, reference($0.1)) }
        let listStyles = table(storage, 7).map { ($0.0, reference($0.1)) }
        let charStyles = table(storage, 8).map { ($0.0, reference($0.1)) }
        let levels = table(storage, 6).map { ($0.0, Int($0.1.first { $0.number == 2 }?.uint ?? 0)) }
        let result = NSMutableAttributedString()
        var lists: [NSTextList] = [], lastListStyle: UInt64?
        var location = 0
        let paragraphs = (raw as String).components(separatedBy: "\n")
        for (number, paragraph) in paragraphs.enumerated() {
            let start = location
            let length = (paragraph as NSString).length
            location += length + 1
            let paraRef = value(at: start, in: paraStyles) ?? nil
            let base = resolved(paraRef, in: styles)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            let listRef = value(at: start, in: listStyles) ?? nil
            let level = max(0, min(8, value(at: start, in: levels) ?? 0))
            if let listRef, let labels = styles[listRef]?.listLabels, labels.indices.contains(level), labels[level] >= 2 {
                // Label type 2 is a bullet, 3 a number; one NSTextList per level.
                if listRef != lastListStyle { lists = [] }
                while lists.count > level + 1 { lists.removeLast() }
                while lists.count < level + 1 {
                    lists.append(NSTextList(markerFormat: labels[lists.count] == 3 ? .decimal : .disc, options: 0))
                }
                style.textLists = lists
                lastListStyle = listRef
            } else {
                lists = []; lastListStyle = nil
            }
            var offset = 0
            let pieces = NSMutableAttributedString()
            while offset < length {
                let index = start + offset
                let nextChange = charStyles.first { $0.0 > index }?.0 ?? Int.max
                let end = min(start + length, nextChange)
                var props = base
                props.merge(resolved(value(at: index, in: charStyles) ?? nil, in: styles))
                let chunk = raw.substring(with: NSRange(location: index, length: end - index))
                    .replacingOccurrences(of: "\u{fffc}", with: "")
                    .replacingOccurrences(of: "\u{2029}", with: "\n")
                pieces.append(NSAttributedString(string: chunk, attributes: [.font: font(props)]))
                offset = end - start
            }
            if number < paragraphs.count - 1 { pieces.append(NSAttributedString(string: "\n", attributes: [.font: font(base)])) }
            pieces.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: pieces.length))
            result.append(pieces)
        }
        return result
    }

    private static func font(_ props: CharProps) -> NSFont {
        let size = max(4, min(400, props.size ?? 11))
        var font = props.font.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if props.bold == true { traits.insert(.boldFontMask) }
        if props.italic == true { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        if props.bold == false, NSFontManager.shared.traits(of: font).contains(.boldFontMask), props.font == nil {
            font = NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        }
        return font
    }
}
