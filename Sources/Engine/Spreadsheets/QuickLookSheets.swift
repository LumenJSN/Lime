import Foundation

/// Reads the per-sheet HTML tables that macOS's Office Quick Look generator
/// produces for a workbook (cell text as displayed).
enum QuickLookSheets {
    static func read(_ url: URL, workspace: URL) async throws -> Workbook {
        let preview = try await QuickLookExport.preview(url, workspace: workspace)
        let folder = preview.html.deletingLastPathComponent()
        let index = try XMLDocument(data: Data(contentsOf: preview.html), options: [.documentTidyHTML])
        let tabs = try index.nodes(forXPath: "//div[contains(@class,'TabViewItem')]")
        var sheets: [Workbook.Sheet] = []
        for (number, tab) in tabs.enumerated() {
            let name = try tab.nodes(forXPath: ".//div[contains(@class,'TabHeader')]").first?.stringValue ?? "Sheet \(number + 1)"
            guard let href = try (tab.nodes(forXPath: ".//a/@href").first)?.stringValue else { continue }
            sheets.append(.init(name: name, rows: try rows(folder.appendingPathComponent(href))))
        }
        if sheets.isEmpty { sheets = [.init(name: FormatCatalog.stem(of: url), rows: try rows(preview.html))] }
        guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw LimeError("This sheet is blank or larger than 128 MB.") }
        return Workbook(sheets: sheets)
    }

    /// Text of every `<td>`, with trailing empty cells and rows trimmed.
    static func rows(_ html: URL) throws -> [[String]] {
        let document = try XMLDocument(data: Data(contentsOf: html), options: [.documentTidyHTML])
        var rows = try document.nodes(forXPath: "//table//tr").map { row -> [String] in
            var cells = try row.nodes(forXPath: "./td|./th").map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            while cells.last?.isEmpty == true { cells.removeLast() }
            return cells
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }
}
