import Foundation

/// Cleans an EPUB chapter body before WebKit renders it. The markup is parsed
/// and rebuilt from allowlists, so nothing in it can load a remote resource,
/// read a file outside the book, or run script.
enum ChapterSanitizer {
    /// Removed together with everything inside them.
    private static let dropped: Set<String> = [
        "script", "noscript", "style", "template", "iframe", "frame", "frameset", "object", "embed", "applet",
        "link", "meta", "base", "form", "input", "button", "select", "textarea", "video", "audio", "source",
        "track", "canvas", "use", "foreignobject", "animate", "set", "pattern", "filter", "mask", "clippath",
    ]
    /// Kept as they are; any other element is replaced by its children.
    private static let kept: Set<String> = [
        "div", "p", "span", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "a", "em", "strong", "b", "i", "u", "s",
        "sub", "sup", "small", "big", "code", "pre", "blockquote", "q", "cite", "abbr", "mark", "del", "ins",
        "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
        "col", "colgroup", "img", "figure", "figcaption", "section", "article", "aside", "header", "footer",
        "nav", "main", "ruby", "rt", "rp", "svg", "g", "image",
    ]
    /// Plain attributes allowed on any kept element.
    private static let plainAttributes: Set<String> = [
        "id", "class", "lang", "xml:lang", "dir", "title", "alt", "colspan", "rowspan", "width", "height",
        "align", "valign", "start", "viewbox", "preserveaspectratio", "x", "y", "version",
    ]

    /// Sanitised markup for a chapter body. Resource paths resolve against
    /// `folder` and must stay inside `root`.
    static func clean(_ body: String, folder: URL, root: URL) -> String {
        guard let container = parse(body) else { return HTMLEscape.text(plainText(body)) }
        clean(element: container, folder: folder, root: root)
        return (container.children ?? []).map { $0.xmlString(options: [.nodeCompactEmptyElement]) }.joined()
    }

    /// Parses the fragment as XHTML first (EPUB chapters usually are), then
    /// through the tolerant HTML parser.
    private static func parse(_ body: String) -> XMLElement? {
        let wrapped = "<div xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">\(body)</div>"
        if let doc = try? XMLDocument(xmlString: wrapped, options: [.nodePreserveWhitespace]), let root = doc.rootElement() { return root }
        guard let doc = try? XMLDocument(xmlString: "<div>\(body)</div>", options: [.documentTidyHTML, .nodePreserveWhitespace]) else { return nil }
        return (try? doc.nodes(forXPath: "//body/div"))?.first as? XMLElement ?? doc.rootElement()
    }

    private static func plainText(_ body: String) -> String {
        body.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
    }

    private static func clean(element: XMLElement, folder: URL, root: URL) {
        var index = 0
        while let children = element.children, index < children.count {
            let child = children[index]
            guard child.kind == .element, let node = child as? XMLElement else {
                if child.kind == .text { index += 1 } else { element.removeChild(at: index) }
                continue
            }
            let name = (node.localName ?? "").lowercased()
            if dropped.contains(name) {
                element.removeChild(at: index)
            } else if kept.contains(name) {
                cleanAttributes(of: node, name: name, folder: folder, root: root)
                clean(element: node, folder: folder, root: root)
                index += 1
            } else {
                // Unknown element: keep its content, lose the element.
                let grandchildren = node.children ?? []
                grandchildren.forEach { $0.detach() }
                element.removeChild(at: index)
                element.insertChildren(grandchildren, at: index)
            }
        }
    }

    private static func cleanAttributes(of node: XMLElement, name: String, folder: URL, root: URL) {
        for attribute in node.attributes ?? [] {
            guard let attributeName = attribute.name else { continue }
            let key = attributeName.lowercased(), value = attribute.stringValue ?? ""
            let replacement: String?
            switch (name, attribute.localName?.lowercased() ?? key) {
            case ("a", "href"):
                replacement = SafeLink.isWebOrMail(value) || value.hasPrefix("#") ? value : nil
            case ("img", "src"), ("image", "href"):
                replacement = value.lowercased().hasPrefix("data:image/") ? value
                    : PackagePath.contained(value, from: folder, in: root)?.absoluteString
            default:
                replacement = plainAttributes.contains(key) ? value : nil
            }
            if let replacement {
                attribute.stringValue = replacement
            } else {
                node.removeAttribute(forName: attributeName)
            }
        }
    }
}
