import Foundation

/// Cell values of a workbook; numbers stay numeric for XLSX/ODS output.
struct Workbook: Sendable {
    struct Sheet: Sendable { var name: String; var rows: [[String]] }
    var sheets: [Sheet]

    static func isNumber(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 32, let first = s.first, first.isNumber || first == "-" || first == "." else { return false }
        if s.count > 1, s.hasPrefix("0"), !s.hasPrefix("0.") { return false }
        return Double(s) != nil
    }
}

enum DelimitedText {
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, atFieldStart = true
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"" where atFieldStart: quoted = true; atFieldStart = false
            case separator: row.append(field); field = ""; atFieldStart = true
            case "\n", "\r\n", "\r":
                row.append(field); rows.append(row); row = []; field = ""; atFieldStart = true
            default: field.append(c); atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func serialize(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { value -> String in
                if separator == "\t" { return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                if value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n") + "\r\n"
    }
}

enum SpreadsheetIO {
    static let limit = 128 * 1024 * 1024

    static func read(_ url: URL, format: String, context: OperationContext) async throws -> Workbook {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0, bytes <= limit else { throw LimeError("This sheet is blank or larger than 128 MB.") }
        switch format {
        case "csv", "tsv":
            let text = try DocumentReader.readText(url)
            let rows = DelimitedText.parse(text, separator: format == "csv" ? (sniffSemicolon(text) ? ";" : ",") : "\t")
            return Workbook(sheets: [.init(name: FormatCatalog.stem(of: url), rows: rows)])
        case "xlsx": return try await XLSX.read(url, workspace: try context.scratchDirectory())
        case "ods": return try await ODS.read(url, workspace: try context.scratchDirectory())
        case "xls":
            if let book = try? XLSReader.read(url), book.sheets.contains(where: { !$0.rows.isEmpty }) { return book }
            // Older BIFF variants: the tables macOS's Office Quick Look generator lays out.
            return try await QuickLookSheets.read(url, workspace: try context.scratchDirectory())
        default: throw LimeError("Lime doesn't know this kind of file.")
        }
    }

    private static func sniffSemicolon(_ text: String) -> Bool {
        let head = text.prefix(4000)
        return head.filter { $0 == ";" }.count > head.filter { $0 == "," }.count * 2
    }

    static func convert(_ source: URL, from format: String, to target: String, context: OperationContext) async throws {
        let book = try await read(source, format: format, context: context)
        guard book.sheets.contains(where: { !$0.rows.isEmpty }) else { throw LimeError("This sheet is blank or larger than 128 MB.") }
        context.progress(0.5)
        try await write(book, source: source, target: target, context: context)
    }

    static func write(_ book: Workbook, source: URL, target: String, context: OperationContext) async throws {
        switch target {
        case "csv", "tsv":
            let separator: Character = target == "csv" ? "," : "\t"
            let sheets = book.sheets.filter { !$0.rows.isEmpty }
            if sheets.count <= 1 {
                try ("\u{feff}" + DelimitedText.serialize(sheets.first?.rows ?? [], separator: separator))
                    .write(to: context.output(for: source, ext: target), atomically: true, encoding: .utf8)
            } else {
                let folder = try context.outputFolder(for: source)
                for sheet in sheets {
                    let name = sheet.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    try ("\u{feff}" + DelimitedText.serialize(sheet.rows, separator: separator))
                        .write(to: folder.appendingPathComponent(name + "." + target), atomically: true, encoding: .utf8)
                }
            }
        case "xlsx": try await XLSX.write(book, to: context.output(for: source, ext: "xlsx"), workspace: context.workspace)
        case "ods": try await ODS.write(book, to: context.output(for: source, ext: "ods"), workspace: context.workspace)
        case "pdf": try SpreadsheetPDF.render(book, to: context.output(for: source, ext: "pdf"))
        default: throw LimeError("Lime can't write \(FormatCatalog.label(target)) here.")
        }
    }

    // MARK: - Cell references

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }
    static func columnIndex(_ reference: String) -> Int {
        var n = 0
        for c in reference.uppercased() {
            guard let a = c.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(0, n - 1)
    }
}
