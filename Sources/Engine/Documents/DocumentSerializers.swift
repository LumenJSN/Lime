import Foundation

enum HTMLEscape {
    static func text(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Link and image targets allowed in documents Lime writes or renders.
enum SafeLink {
    /// The target as a browser reads it: spaces and control characters dropped.
    private static func normalized(_ link: String) -> String {
        String(String.UnicodeScalarView(link.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
    }
    private static func hasScheme(_ link: String) -> Bool {
        normalized(link).range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
    }

    static func isWebOrMail(_ link: String) -> Bool {
        let lower = normalized(link).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    /// Web and mail links, plus relative and in-page ones. `javascript:`,
    /// `file:`, `data:` and other schemes are refused.
    static func isAllowedLink(_ link: String) -> Bool { isWebOrMail(link) || !hasScheme(link) }

    /// Inline images, or relative paths that stay inside the document's folder.
    /// Remote images are refused so rendering never reaches the network.
    static func isAllowedImage(_ source: String) -> Bool {
        let path = normalized(source)
        if path.lowercased().hasPrefix("data:image/") { return true }
        return !path.isEmpty && !hasScheme(path) && !path.hasPrefix("/") && !path.hasPrefix("\\")
            && !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }
}

/// Serialises a `SemanticDocument` to HTML/XHTML and Markdown.
enum DocumentSerializer {
    /// `imageSource` decides how images are referenced (data URI or file).
    static func html(_ document: SemanticDocument, title: String, xhtml: Bool = false, imageSource: (SemanticDocument.Image) -> String? = dataURI) -> String {
        var body = ""
        var openList: (ordered: Bool, level: Int)?
        func closeList() { if let list = openList { body += list.ordered ? "</ol>\n" : "</ul>\n"; openList = nil } }
        for block in document.blocks {
            if case .listItem(let ordered, let level, let inlines) = block {
                if openList == nil || openList!.ordered != ordered || openList!.level != level {
                    closeList(); body += ordered ? "<ol>\n" : "<ul>\n"; openList = (ordered, level)
                }
                body += "<li>\(inlineHTML(inlines, xhtml: xhtml, imageSource: imageSource))</li>\n"
                continue
            }
            closeList()
            switch block {
            case .heading(let level, let inlines): body += "<h\(level)>\(inlineHTML(inlines, xhtml: xhtml, imageSource: imageSource))</h\(level)>\n"
            case .paragraph(let inlines): body += "<p>\(inlineHTML(inlines, xhtml: xhtml, imageSource: imageSource))</p>\n"
            case .table(let rows):
                body += "<table>\n"
                for (index, row) in rows.enumerated() {
                    let tag = index == 0 && rows.count > 1 ? "th" : "td"
                    body += "<tr>" + row.map { "<\(tag)>\(inlineHTML($0, xhtml: xhtml, imageSource: imageSource))</\(tag)>" }.joined() + "</tr>\n"
                }
                body += "</table>\n"
            case .rule: body += xhtml ? "<hr/>\n" : "<hr>\n"
            case .listItem: break
            }
        }
        closeList()
        let style = """
        body{font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;line-height:1.5;max-width:46em;margin:2em auto;padding:0 1em;color:#1d1d1f}
        img{max-width:100%;height:auto}table{border-collapse:collapse;margin:1em 0}td,th{border:1px solid #ccc;padding:.35em .6em;text-align:left;vertical-align:top}
        code{font-family:Menlo,monospace;background:#f2f2f2;padding:0 .2em;border-radius:3px}pre{background:#f2f2f2;padding:.8em;overflow:auto}
        """
        if xhtml {
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><meta charset="UTF-8"/><title>\(HTMLEscape.text(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
            \(body)</body>
            </html>
            """
        }
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(HTMLEscape.text(title))</title>
        <style>\(style)</style></head>
        <body>
        \(body)</body>
        </html>
        """
    }

    static func dataURI(_ image: SemanticDocument.Image) -> String? {
        "data:image/\(image.ext);base64," + image.data.base64EncodedString()
    }

    static func inlineHTML(_ inlines: [SemanticDocument.Inline], xhtml: Bool, imageSource: (SemanticDocument.Image) -> String?) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case .image(let image):
                if let src = imageSource(image) { result += "<img src=\"\(src)\" alt=\"\"\(xhtml ? "/" : "")>" }
            case .run(let run):
                var piece = HTMLEscape.text(run.text).replacingOccurrences(of: "\n", with: xhtml ? "<br/>" : "<br>")
                if run.code { piece = "<code>\(piece)</code>" }
                if run.bold { piece = "<strong>\(piece)</strong>" }
                if run.italic { piece = "<em>\(piece)</em>" }
                if run.underline { piece = "<u>\(piece)</u>" }
                if run.strike { piece = "<s>\(piece)</s>" }
                if let link = run.link, SafeLink.isAllowedLink(link) { piece = "<a href=\"\(HTMLEscape.text(link))\">\(piece)</a>" }
                result += piece
            }
        }
        return result
    }

    static func markdown(_ document: SemanticDocument) -> String {
        var lines: [String] = []
        var previousWasList = false
        var counters: [Int: Int] = [:], kinds: [Int: Bool] = [:]
        for block in document.blocks {
            if case .listItem(let ordered, let level, let inlines) = block {
                if !previousWasList { counters = [:]; kinds = [:] }
                // A new list kind at a level restarts numbering (and needs a blank line at the top level).
                if let kind = kinds[level], kind != ordered {
                    counters[level] = 0
                    if level == 0 { lines.append("") }
                }
                kinds[level] = ordered
                counters = counters.filter { $0.key <= level }
                kinds = kinds.filter { $0.key <= level }
                let number = (counters[level] ?? 0) + 1
                counters[level] = number
                lines.append(String(repeating: "   ", count: level) + (ordered ? "\(number). " : "- ") + inlineMarkdown(inlines))
                previousWasList = true
                continue
            }
            if previousWasList { lines.append("") }
            previousWasList = false
            switch block {
            case .heading(let level, let inlines): lines.append(String(repeating: "#", count: min(6, level)) + " " + inlineMarkdown(inlines)); lines.append("")
            case .paragraph(let inlines): lines.append(inlineMarkdown(inlines)); lines.append("")
            case .table(let rows):
                guard let header = rows.first else { continue }
                let width = rows.map(\.count).max() ?? header.count
                func row(_ cells: [[SemanticDocument.Inline]]) -> String {
                    let padded = cells.map { inlineMarkdown($0).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                        + Array(repeating: "", count: max(0, width - cells.count))
                    return "| " + padded.joined(separator: " | ") + " |"
                }
                lines.append(row(header))
                lines.append("|" + Array(repeating: " --- |", count: width).joined())
                for r in rows.dropFirst() { lines.append(row(r)) }
                lines.append("")
            case .rule: lines.append("---"); lines.append("")
            case .listItem: break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func inlineMarkdown(_ inlines: [SemanticDocument.Inline]) -> String {
        inlines.map { inline -> String in
            guard case .run(let run) = inline else { return "" }
            let text = run.text
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            var piece = run.code ? "`\(core)`" : escapeMarkdown(core).replacingOccurrences(of: "\n", with: "  \n")
            if run.bold && run.italic { piece = "***\(piece)***" } else if run.bold { piece = "**\(piece)**" } else if run.italic { piece = "*\(piece)*" }
            if run.strike { piece = "~~\(piece)~~" }
            if let link = run.link { piece = "[\(piece)](\(link))" }
            let leading = text.prefix(while: { $0 == " " }), trailing = String(text.reversed().prefix(while: { $0 == " " }))
            return leading + piece + trailing
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeMarkdown(_ s: String) -> String {
        var out = ""
        for c in s { if "\\`*_[]#".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }
}

/// Small CommonMark-style renderer for Markdown input.
enum MarkdownRenderer {
    static func html(from markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count < 500_000 else { return "<p>Markdown has too many lines.</p>" }
        var body = ""
        var paragraph: [String] = []
        var listStack: [String] = []
        var inCode = false
        var code: [String] = []
        var index = 0
        func flushParagraph() {
            if !paragraph.isEmpty { body += "<p>" + inline(paragraph.joined(separator: "\n")) + "</p>\n"; paragraph = [] }
        }
        func closeLists(to depth: Int = 0) { while listStack.count > depth { body += "</\(listStack.removeLast())>\n" } }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode { body += "<pre><code>" + HTMLEscape.text(code.joined(separator: "\n")) + "</code></pre>\n"; code = []; inCode = false }
                else { flushParagraph(); closeLists(); inCode = true }
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); closeLists(); continue }
            if let level = headingLevel(trimmed) {
                flushParagraph(); closeLists()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                body += "<h\(level)>\(inline(text))</h\(level)>\n"; continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && paragraph.isEmpty {
                closeLists(); body += "<hr>\n"; continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                body += "<blockquote><p>" + inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)) + "</p></blockquote>\n"; continue
            }
            if trimmed.hasPrefix("|"), index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flushParagraph(); closeLists()
                var rows = [cells(trimmed)]
                index += 1
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces))); index += 1
                }
                body += "<table>\n" + rows.enumerated().map { i, row in
                    "<tr>" + row.map { i == 0 ? "<th>\(inline($0))</th>" : "<td>\(inline($0))</td>" }.joined() + "</tr>"
                }.joined(separator: "\n") + "\n</table>\n"
                continue
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let (ordered, text) = listItem(trimmed) {
                flushParagraph()
                let depth = indent / 2 + 1
                let tag = ordered ? "ol" : "ul"
                if listStack.count > depth { closeLists(to: depth) }
                if listStack.count == depth, listStack.last != tag { closeLists(to: depth - 1) }
                while listStack.count < depth { body += "<\(tag)>\n"; listStack.append(tag) }
                body += "<li>\(inline(text))</li>\n"; continue
            }
            closeLists()
            paragraph.append(trimmed)
        }
        if inCode { body += "<pre><code>" + HTMLEscape.text(code.joined(separator: "\n")) + "</code></pre>\n" }
        flushParagraph(); closeLists()
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:Helvetica;font-size:12pt\">\n\(body)</body></html>"
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.count == hashes || s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }
    private static func listItem(_ s: String) -> (Bool, String)? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            var text = String(s.dropFirst(2))
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) } else if text.lowercased().hasPrefix("[x] ") { text = "☑ " + text.dropFirst(4) }
            return (false, text)
        }
        if let r = s.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) { return (true, String(s[r.upperBound...])) }
        return nil
    }
    private static func cells(_ row: String) -> [String] {
        var s = row
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func inline(_ text: String) -> String {
        var s = HTMLEscape.text(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*\*([^*]+)\*\*\*"#, "<strong><em>$1</em></strong>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            // `*` may emphasise inside words (CommonMark); `_` may not.
            (#"(?<![*\\])\*(?![\s*])([^*\n]*?[^\s*])\*(?!\*)"#, "<em>$1</em>"),
            (#"(?<![\w_])_([^_\n]+)_(?!\w)"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<s>$1</s>"),
            (#"\\([\\`*_\[\]#+\-.!|])"#, "$1"),
        ]
        s = s.replacingOccurrences(of: rules[0].0, with: rules[0].1, options: .regularExpression)
        s = links(in: s)
        for (pattern, template) in rules.dropFirst() {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.replacingOccurrences(of: "  \n", with: "<br>").replacingOccurrences(of: "\n", with: " ")
    }

    /// Markdown images and links in already-escaped text. Targets that
    /// `SafeLink` refuses keep only their visible text.
    private static func links(in text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(!?)\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#) else { return text }
        var result = "", cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let bang = Range(match.range(at: 1), in: text),
                  let label = Range(match.range(at: 2), in: text), let target = Range(match.range(at: 3), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            let (name, url) = (String(text[label]), String(text[target]))
            if !text[bang].isEmpty {
                result += SafeLink.isAllowedImage(url) ? "<img src=\"\(url)\" alt=\"\(name)\">" : name
            } else if !name.isEmpty {
                result += SafeLink.isAllowedLink(url) ? "<a href=\"\(url)\">\(name)</a>" : name
            } else {
                result += text[whole]
            }
            cursor = whole.upperBound
        }
        return result + text[cursor...]
    }
}
