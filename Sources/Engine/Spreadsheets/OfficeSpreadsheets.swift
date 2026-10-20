import AppKit

/// Office Open XML workbooks.
enum XLSX {
    static func read(_ url: URL, workspace: URL) async throws -> Workbook {
        try await ZipPackage.extract(url, to: workspace)
        let workbookXML = try XMLDocument(contentsOf: workspace.appendingPathComponent("xl/workbook.xml"), options: [])
        var targets: [String: String] = [:]
        if let rels = try? XMLDocument(contentsOf: workspace.appendingPathComponent("xl/_rels/workbook.xml.rels"), options: []) {
            for node in try rels.nodes(forXPath: "//*[local-name()='Relationship']") {
                guard let e = node as? XMLElement, let id = e.attribute(forName: "Id")?.stringValue, let target = e.attribute(forName: "Target")?.stringValue else { continue }
                targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        var shared: [String] = []
        if let sst = try? XMLDocument(contentsOf: workspace.appendingPathComponent("xl/sharedStrings.xml"), options: []) {
            shared = try sst.nodes(forXPath: "//*[local-name()='si']").map { si in
                (try? si.nodes(forXPath: ".//*[local-name()='t']").compactMap(\.stringValue).joined()) ?? ""
            }
        }
        let dateStyles = dateStyleIndexes(workspace)
        var sheets: [Workbook.Sheet] = []
        for (index, node) in try workbookXML.nodes(forXPath: "//*[local-name()='sheet']").enumerated() {
            guard let e = node as? XMLElement else { continue }
            let name = e.attribute(forName: "name")?.stringValue ?? "Sheet \(index + 1)"
            let rid = e.attributes?.first(where: { $0.localName == "id" })?.stringValue ?? ""
            let path = targets[rid] ?? "xl/worksheets/sheet\(index + 1).xml"
            let sheetURL = workspace.appendingPathComponent(path).standardizedFileURL
            guard sheetURL.path.hasPrefix(workspace.standardizedFileURL.path), let sheetXML = try? XMLDocument(contentsOf: sheetURL, options: []) else { continue }
            var grid: [[String]] = []
            for rowNode in try sheetXML.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']") {
                guard let row = rowNode as? XMLElement else { continue }
                let rowIndex = (Int(row.attribute(forName: "r")?.stringValue ?? "") ?? grid.count + 1) - 1
                guard rowIndex >= 0, rowIndex < 1_048_576 else { continue }
                while grid.count <= rowIndex { grid.append([]) }
                var nextColumn = 0
                for cellNode in row.children ?? [] {
                    guard let cell = cellNode as? XMLElement, cell.localName == "c" else { continue }
                    let ref = cell.attribute(forName: "r")?.stringValue
                    let column = ref.map(SpreadsheetIO.columnIndex) ?? nextColumn
                    nextColumn = column + 1
                    guard column < 16_384 else { continue }
                    let type = cell.attribute(forName: "t")?.stringValue
                    let raw = cell.elements(forName: "v").first?.stringValue ?? ""
                    var value: String
                    switch type {
                    case "s": value = Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                    case "inlineStr": value = (try? cell.nodes(forXPath: ".//*[local-name()='t']").compactMap(\.stringValue).joined()) ?? ""
                    case "b": value = raw == "1" ? "TRUE" : "FALSE"
                    default:
                        value = raw
                        if let style = Int(cell.attribute(forName: "s")?.stringValue ?? ""), dateStyles.contains(style), let serial = Double(raw) {
                            value = excelDate(serial)
                        }
                    }
                    while grid[rowIndex].count <= column { grid[rowIndex].append("") }
                    grid[rowIndex][column] = value
                }
            }
            sheets.append(.init(name: name, rows: trim(grid)))
        }
        guard !sheets.isEmpty else { throw LimeError("This sheet is blank or larger than 128 MB.") }
        return Workbook(sheets: sheets)
    }

    private static func dateStyleIndexes(_ root: URL) -> Set<Int> {
        guard let styles = try? XMLDocument(contentsOf: root.appendingPathComponent("xl/styles.xml"), options: []) else { return [] }
        var customDates = Set<Int>()
        for node in (try? styles.nodes(forXPath: "//*[local-name()='numFmt']")) ?? [] {
            guard let e = node as? XMLElement, let id = Int(e.attribute(forName: "numFmtId")?.stringValue ?? ""),
                  let code = e.attribute(forName: "formatCode")?.stringValue?.lowercased() else { continue }
            let stripped = code.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*""#, with: "", options: .regularExpression)
            if stripped.contains("y") || (stripped.contains("d") && stripped.contains("m")) { customDates.insert(id) }
        }
        var result = Set<Int>()
        let xfs = (try? styles.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']")) ?? []
        for (index, node) in xfs.enumerated() {
            guard let e = node as? XMLElement, let id = Int(e.attribute(forName: "numFmtId")?.stringValue ?? "") else { continue }
            if (14...22).contains(id) || customDates.contains(id) { result.insert(index) }
        }
        return result
    }

    private static func excelDate(_ serial: Double) -> String {
        let base = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 1899, month: 12, day: 30).date!
        let date = base.addingTimeInterval(serial * 86400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func trim(_ grid: [[String]]) -> [[String]] {
        var rows = grid
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        return rows.map { row in var r = row; while let l = r.last, l.isEmpty { r.removeLast() }; return r }
    }

    static func write(_ book: Workbook, to destination: URL, workspace: URL) async throws {
        var files: [String: Data] = [:]
        let sheets = book.sheets.isEmpty ? [Workbook.Sheet(name: "Sheet 1", rows: [])] : book.sheets
        var usedNames = Set<String>()
        let names = sheets.enumerated().map { index, sheet -> String in
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if name.isEmpty { name = "Sheet \(index + 1)" }
            var candidate = name; var n = 2
            while usedNames.contains(candidate.lowercased()) { candidate = String(name.prefix(28)) + " \(n)"; n += 1 }
            usedNames.insert(candidate.lowercased())
            return candidate
        }
        files["[Content_Types].xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        \(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())
        </Types>
        """.utf8)
        files["_rels/.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8)
        files["xl/workbook.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
        \(names.enumerated().map { "<sheet name=\"\(XMLText.escape($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())
        </sheets></workbook>
        """.utf8)
        files["xl/_rels/workbook.xml.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())
        <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """.utf8)
        files["xl/styles.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="1"><xf xfId="0"/></cellXfs></styleSheet>
        """.utf8)
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = SpreadsheetIO.columnName(c) + String(r + 1)
                    if Workbook.isNumber(value) { xml += "<c r=\"\(ref)\"><v>\(value)</v></c>" }
                    else { xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(value))</t></is></c>" }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            files["xl/worksheets/sheet\(index + 1).xml"] = Data(xml.utf8)
        }
        try await ZipPackage.write(files, to: destination, workspace: workspace)
    }
}

/// OpenDocument spreadsheets.
enum ODS {
    static func read(_ url: URL, workspace: URL) async throws -> Workbook {
        try await ZipPackage.extract(url, to: workspace)
        let content = try XMLDocument(contentsOf: workspace.appendingPathComponent("content.xml"), options: [])
        var sheets: [Workbook.Sheet] = []
        for tableNode in try content.nodes(forXPath: "//*[local-name()='spreadsheet']/*[local-name()='table']") {
            guard let table = tableNode as? XMLElement else { continue }
            let name = table.attributes?.first(where: { $0.localName == "name" })?.stringValue ?? "Sheet \(sheets.count + 1)"
            var grid: [[String]] = []
            for rowNode in try table.nodes(forXPath: ".//*[local-name()='table-row']") {
                guard let row = rowNode as? XMLElement else { continue }
                var cells: [String] = []
                for cellNode in row.children ?? [] {
                    guard let cell = cellNode as? XMLElement, ["table-cell", "covered-table-cell"].contains(cell.localName ?? "") else { continue }
                    let repeatCount = min(1024, Int(cell.attributes?.first(where: { $0.localName == "number-columns-repeated" })?.stringValue ?? "1") ?? 1)
                    let value = cell.attributes?.first(where: { $0.localName == "value" || $0.localName == "date-value" })?.stringValue
                        ?? ((try? cell.nodes(forXPath: ".//*[local-name()='p']").compactMap(\.stringValue).joined(separator: "\n")) ?? "")
                    cells.append(contentsOf: Array(repeating: value, count: repeatCount))
                }
                let rowRepeat = min(1024, Int(row.attributes?.first(where: { $0.localName == "number-rows-repeated" })?.stringValue ?? "1") ?? 1)
                for _ in 0..<rowRepeat { grid.append(cells) }
                if grid.count > 1_048_576 { break }
            }
            sheets.append(.init(name: name, rows: XLSX.trim(grid)))
        }
        guard !sheets.isEmpty else { throw LimeError("This sheet is blank or larger than 128 MB.") }
        return Workbook(sheets: sheets)
    }

    static func write(_ book: Workbook, to destination: URL, workspace: URL) async throws {
        var body = ""
        for sheet in book.sheets {
            body += "<table:table table:name=\"\(XMLText.escape(sheet.name))\">"
            for row in sheet.rows {
                body += "<table:table-row>"
                for value in row {
                    if value.isEmpty { body += "<table:table-cell/>" }
                    else if Workbook.isNumber(value) { body += "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\"><text:p>\(value)</text:p></table:table-cell>" }
                    else {
                        let paragraphs = value.components(separatedBy: "\n").map { "<text:p>\(XMLText.escape($0))</text:p>" }.joined()
                        body += "<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    }
                }
                body += "</table:table-row>"
            }
            body += "</table:table>"
        }
        let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\""
        let files: [String: Data] = [
            "mimetype": Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
            "META-INF/manifest.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
            <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
            </manifest:manifest>
            """.utf8),
            "content.xml": Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content \(ns) office:version=\"1.2\"><office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body></office:document-content>".utf8),
        ]
        try await ZipPackage.write(files, to: destination, storedFirst: "mimetype", workspace: workspace)
    }
}

/// Paginated grid rendering for spreadsheet → PDF.
enum SpreadsheetPDF {
    static func render(_ book: Workbook, to destination: URL) throws {
        let page = DocumentRenderer.defaultPageSize
        let landscape = CGSize(width: page.height, height: page.width)
        let margin: CGFloat = 36, padding: CGFloat = 4
        let font = NSFont.systemFont(ofSize: 9), bold = NSFont.boldSystemFont(ofSize: 9)
        guard let consumer = CGDataConsumer(url: destination as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw LimeError("Lime couldn't write the PDF.")
        }
        var pages = 0
        for sheet in book.sheets where !sheet.rows.isEmpty {
            let columns = sheet.rows.map(\.count).max() ?? 0
            var widths = [CGFloat](repeating: 30, count: columns)
            for row in sheet.rows.prefix(2000) {
                for (c, value) in row.enumerated() {
                    let w = (value.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + padding * 2
                    widths[c] = min(220, max(widths[c], w))
                }
            }
            let pageSize = widths.reduce(0, +) > page.width - margin * 2 ? landscape : page
            let usable = pageSize.width - margin * 2
            // Split columns into horizontal page bands.
            var bands: [Range<Int>] = []
            var start = 0, running: CGFloat = 0
            for (i, w) in widths.enumerated() {
                if running + w > usable, i > start { bands.append(start..<i); start = i; running = 0 }
                running += w
            }
            if start < columns { bands.append(start..<columns) }
            for band in bands {
                var rowIndex = 0
                while rowIndex < sheet.rows.count {
                    try Task.checkCancellation()
                    var box = CGRect(origin: .zero, size: pageSize)
                    context.beginPage(mediaBox: &box); pages += 1
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    var y = pageSize.height - margin
                    let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black]
                    (sheet.name as NSString).draw(at: CGPoint(x: margin, y: y - 12), withAttributes: titleAttributes)
                    y -= 22
                    while rowIndex < sheet.rows.count {
                        let row = sheet.rows[rowIndex]
                        let lines = CGFloat(row.map { $0.components(separatedBy: "\n").count }.max() ?? 1)
                        let height = min(120, 13 * lines) + padding
                        if y - height < margin { break }
                        var x = margin
                        for c in band {
                            let w = widths[c]
                            let rect = CGRect(x: x, y: y - height, width: w, height: height)
                            context.setStrokeColor(NSColor(white: 0.75, alpha: 1).cgColor)
                            context.setLineWidth(0.5)
                            context.stroke(rect)
                            let value = c < row.count ? row[c] : ""
                            let attributes: [NSAttributedString.Key: Any] = [.font: rowIndex == 0 ? bold : font, .foregroundColor: NSColor.black]
                            (value as NSString).draw(with: rect.insetBy(dx: padding, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
                            x += w
                        }
                        y -= height
                        rowIndex += 1
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    context.endPage()
                }
            }
        }
        context.closePDF()
        guard pages > 0 else { throw LimeError("This sheet is blank or larger than 128 MB.") }
    }
}
