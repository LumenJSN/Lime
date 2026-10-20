import Foundation

/// ZIP containers for OOXML, ODF and EPUB packages.
enum ZipPackage {
    /// Zips `directory`; `storedFirst` (EPUB `mimetype`) goes first, uncompressed.
    static func create(from directory: URL, to destination: URL, storedFirst: String? = nil) async throws {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        try? FileManager.default.removeItem(at: destination)
        if let storedFirst {
            try await ProcessRunner.run(zip, ["-X0q", destination.path, storedFirst], directory: directory)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != storedFirst && !$0.hasPrefix(".") }.sorted()
        guard !entries.isEmpty else { return }
        try await ProcessRunner.run(zip, ["-Xr9Dq", destination.path] + entries, directory: directory)
    }

    /// Extracts with bsdtar, which refuses absolute and parent-relative members.
    static func extract(_ archive: URL, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/bsdtar"), ["-xf", archive.path, "-C", directory.path, "--no-same-owner"])
    }

    static func write(_ files: [String: Data], to destination: URL, storedFirst: String? = nil, workspace: URL) async throws {
        let root = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try await create(from: root, to: destination, storedFirst: storedFirst)
    }
}

enum XMLText {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if scalar.value < 0x20, ![0x9, 0xA, 0xD].contains(scalar.value) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// EPUB 3 writer for reflowable chapters or fixed-layout page images.
enum EPUBWriter {
    static func write(_ document: SemanticDocument, title: String, to destination: URL, workspace: URL) async throws {
        var files: [String: Data] = [:]
        var images: [(String, Data)] = []
        func imageSource(_ image: SemanticDocument.Image) -> String? {
            let name = "images/image-\(images.count + 1).\(image.ext)"
            images.append((name, image.data))
            return name
        }
        // Split chapters at top-level headings.
        let topLevel = document.blocks.compactMap { if case .heading(let l, _) = $0 { return l }; return nil }.min() ?? 1
        var chapters: [SemanticDocument] = []
        var current = SemanticDocument()
        for block in document.blocks {
            if case .heading(let level, let inlines) = block, level == topLevel, !current.blocks.isEmpty {
                chapters.append(current); current = SemanticDocument(); current.title = SemanticDocument.text(inlines)
            } else if case .heading(let level, let inlines) = block, level == topLevel { current.title = SemanticDocument.text(inlines) }
            current.blocks.append(block)
        }
        if !current.blocks.isEmpty || chapters.isEmpty { chapters.append(current) }
        guard chapters.count <= 5000 else { throw LimeError("This document has more parts than Lime can handle.") }
        var navItems: [(String, String)] = []
        for (index, chapter) in chapters.enumerated() {
            let name = String(format: "chapter-%04d.xhtml", index + 1)
            let chapterTitle = chapter.title ?? (chapters.count == 1 ? title : "Section \(index + 1)")
            files["OEBPS/" + name] = Data(DocumentSerializer.html(chapter, title: chapterTitle, xhtml: true, imageSource: imageSource).utf8)
            navItems.append((name, chapterTitle))
        }
        for (name, data) in images { files["OEBPS/" + name] = data }
        files["OEBPS/style.css"] = Data("body{font-family:serif;line-height:1.5}img{max-width:100%}table{border-collapse:collapse}td,th{border:1px solid #999;padding:.2em .4em}".utf8)
        let manifest = navItems.enumerated().map { "<item id=\"c\($0.offset + 1)\" href=\"\($0.element.0)\" media-type=\"application/xhtml+xml\"/>" }
            + images.enumerated().map { "<item id=\"img\($0.offset + 1)\" href=\"\($0.element.0)\" media-type=\"image/png\"/>" }
        let spine = navItems.indices.map { "<itemref idref=\"c\($0 + 1)\"/>" }
        try await package(files: files, title: title, manifest: manifest, spine: spine, nav: navItems, fixed: false, to: destination, workspace: workspace)
    }

    static func writeFixed(pages: [Data], pageSize: CGSize, title: String, to destination: URL, workspace: URL) async throws {
        var files: [String: Data] = [:]
        var manifest: [String] = [], spine: [String] = [], nav: [(String, String)] = []
        let w = Int(pageSize.width), h = Int(pageSize.height)
        for (index, data) in pages.enumerated() {
            let page = String(format: "page-%04d", index + 1)
            files["OEBPS/images/\(page).jpg"] = data
            files["OEBPS/\(page).xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="UTF-8"/><meta name="viewport" content="width=\(w), height=\(h)"/><title>\(index + 1)</title>
            <style>html,body{margin:0;padding:0}img{width:\(w)px;height:\(h)px;display:block}</style></head>
            <body><img src="images/\(page).jpg" alt="Page \(index + 1)"/></body></html>
            """.utf8)
            manifest.append("<item id=\"p\(index + 1)\" href=\"\(page).xhtml\" media-type=\"application/xhtml+xml\"/>")
            manifest.append("<item id=\"i\(index + 1)\" href=\"images/\(page).jpg\" media-type=\"image/jpeg\"/>")
            spine.append("<itemref idref=\"p\(index + 1)\"/>")
            nav.append(("\(page).xhtml", "Page \(index + 1)"))
        }
        try await package(files: files, title: title, manifest: manifest, spine: spine, nav: nav, fixed: true, to: destination, workspace: workspace)
    }

    private static func package(files input: [String: Data], title: String, manifest: [String], spine: [String], nav: [(String, String)],
                                fixed: Bool, to destination: URL, workspace: URL) async throws {
        var files = input
        files["mimetype"] = Data("application/epub+zip".utf8)
        files["META-INF/container.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
        let navBody = nav.map { "<li><a href=\"\($0.0)\">\(XMLText.escape($0.1))</a></li>" }.joined(separator: "\n")
        files["OEBPS/nav.xhtml"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><meta charset="UTF-8"/><title>Contents</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
        \(navBody)
        </ol></nav></body></html>
        """.utf8)
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let layout = fixed ? "<meta property=\"rendition:layout\">pre-paginated</meta><meta property=\"rendition:spread\">none</meta>" : ""
        let css = files["OEBPS/style.css"] == nil ? "" : "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>"
        files["OEBPS/content.opf"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
        <dc:title>\(XMLText.escape(title))</dc:title><dc:language>en</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>\(layout)
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\(css)
        \(manifest.joined(separator: "\n"))
        </manifest>
        <spine>
        \(spine.joined(separator: "\n"))
        </spine>
        </package>
        """.utf8)
        try await ZipPackage.write(files, to: destination, storedFirst: "mimetype", workspace: workspace)
    }
}

/// Reads an EPUB's spine into one HTML document.
enum EPUBReader {
    struct Book { let html: String; let baseURL: URL; let title: String }

    static func read(_ url: URL, workspace: URL) async throws -> Book {
        let root = workspace.appendingPathComponent("epub", isDirectory: true)
        try await ZipPackage.extract(url, to: root)
        let container = try XMLDocument(contentsOf: root.appendingPathComponent("META-INF/container.xml"), options: [])
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw LimeError("Lime couldn't open the file.")
        }
        let opfURL = root.appendingPathComponent(opfPath)
        guard opfURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { throw LimeError("A file inside the document points outside its package.") }
        let opf = try XMLDocument(contentsOf: opfURL, options: [])
        let base = opfURL.deletingLastPathComponent()
        var manifest: [String: String] = [:]
        for node in try opf.nodes(forXPath: "//*[local-name()='item']") {
            guard let element = node as? XMLElement, let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = href.removingPercentEncoding ?? href
        }
        let title = try opf.nodes(forXPath: "//*[local-name()='title']").first?.stringValue ?? FormatCatalog.stem(of: url)
        var body = ""
        for node in try opf.nodes(forXPath: "//*[local-name()='itemref']/@idref") {
            guard let id = node.stringValue, let href = manifest[id] else { continue }
            let chapter = base.appendingPathComponent(href).standardizedFileURL
            guard chapter.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: chapter) else { continue }
            var html = String(decoding: data, as: UTF8.self)
            if let start = html.range(of: "<body", options: .caseInsensitive), let open = html[start.upperBound...].firstIndex(of: ">"),
               let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                html = String(html[html.index(after: open)..<end.lowerBound])
            }
            let folder = chapter.deletingLastPathComponent()
            html = html.replacingOccurrences(of: #"(src|xlink:href)="(?!data:|https?:)([^"]+)""#, with: "$1=\"\(folder.absoluteString)$2\"", options: .regularExpression)
            body += "<div class=\"chapter\">\n" + html + "\n</div>\n"
        }
        guard !body.isEmpty else { throw LimeError("This document is blank.") }
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(HTMLEscape.text(title))</title></head><body>\(body)</body></html>"
        return Book(html: html, baseURL: base, title: title)
    }
}
