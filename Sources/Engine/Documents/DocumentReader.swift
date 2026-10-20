import AppKit

/// Reads every document input format into an attributed string.
enum DocumentReader {
    static let importLimit = 128 * 1024 * 1024

    static func read(_ url: URL, format: String, context: OperationContext) async throws -> NSAttributedString {
        let size = (try? url.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey]))
        if let bytes = size?.totalFileSize ?? size?.fileSize, bytes > importLimit {
            throw LimeError("This document is blank or larger than 128 MB.")
        }
        switch format {
        case "docx":
            if let text = try? await DOCXReader.read(url, workspace: context.workspace), text.length > 0 { return text }
            return try attributed(url, type: .officeOpenXML)
        case "odt": return try attributed(url, type: .openDocument)
        case "rtf": return try attributed(url, type: .rtf)
        case "rtfd": return try attributed(url, type: .rtfd)
        case "html": return try attributed(url, type: .html)
        case "txt": return plain(try readText(url))
        case "md": return try html(MarkdownRenderer.html(from: try readText(url)), baseURL: url.deletingLastPathComponent())
        case "textClipping": return try TextClipping.read(url)
        case "epub":
            let book = try await EPUBReader.read(url, workspace: try context.scratchDirectory())
            return try html(book.html, baseURL: book.baseURL)
        case "pages":
            // Body text straight from the IWA archives; the Quick Look layout is the fallback.
            if let text = try? await PagesReader.read(url, workspace: try context.scratchDirectory()), text.length > 0 { return text }
            let pdf = try await QuickLookExport.documentPDF(url, workspace: try context.scratchDirectory())
            return try await PDFConverter.attributedText(pdf, context: nil)
        default:
            throw LimeError("Lime doesn't know this kind of file.")
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= 32 * 1024 * 1024 else { throw LimeError("This text file is unreadable or larger than 32 MB.") }
        if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw LimeError("This text file is unreadable or larger than 32 MB.")
    }

    static func attributed(_ url: URL, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        } catch {
            throw LimeError("Lime couldn't open the file.")
        }
    }

    static func html(_ html: String, baseURL: URL?) throws -> NSAttributedString {
        let data = Data(html.utf8)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html,
                                                                         .characterEncoding: String.Encoding.utf8.rawValue]
        if let baseURL { options[.baseURL] = baseURL }
        // WebKit-backed HTML import must run on the main thread.
        let result: NSAttributedString? = DispatchQueue.main.syncIfNeeded {
            try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        }
        guard let result else { throw LimeError("The Markdown has embedded HTML that is too big or declares entities.") }
        return result
    }

    static func plain(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style])
    }
}

extension DispatchQueue {
    func syncIfNeeded<T>(_ work: () -> T) -> T {
        if self === DispatchQueue.main, Thread.isMainThread { return work() }
        return sync(execute: work)
    }
}

/// Finder text clippings: a property list holding UTI-keyed payloads.
enum TextClipping {
    static func read(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let payloads = plist["UTI-Data"] as? [String: Any] else {
            throw LimeError("This clipping is damaged or in a layout Lime doesn't know.")
        }
        if let rtf = payloads["public.rtf"] as? Data,
           let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return text
        }
        for key in ["public.utf8-plain-text", "public.plain-text", "public.utf16-plain-text"] {
            if let text = payloads[key] as? String { return DocumentReader.plain(text) }
            if let data = payloads[key] as? Data, let text = String(data: data, encoding: key.contains("utf16") ? .utf16 : .utf8) {
                return DocumentReader.plain(text)
            }
        }
        if let html = payloads["public.html"] as? String { return try DocumentReader.html(html, baseURL: nil) }
        throw LimeError("The clipping has no text Lime can use.")
    }
}
