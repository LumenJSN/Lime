import AppKit
import PDFKit
import WebKit

/// Renders PowerPoint and iWork files with the Quick Look generators that ship
/// with macOS (`qlmanage -p`, the engine behind Finder previews), so no
/// presentation or word-processing app has to be installed or launched.
enum QuickLookExport {
    struct Preview {
        let html: URL
        let attachments: [URL]
        var pdf: URL? { attachments.first { $0.pathExtension.lowercased() == "pdf" } }
    }

    static let timeout: TimeInterval = 120

    /// Writes the HTML preview and its attachments into a fresh scratch folder.
    static func preview(_ source: URL, workspace: URL) async throws -> Preview {
        let folder = workspace.appendingPathComponent("quicklook-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runner = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-p", "-o", folder.path, source.path]) }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            runner.cancel()
        }
        defer { watchdog.cancel() }
        do { _ = try await runner.value } catch {
            throw LimeError("macOS couldn't open \(source.lastPathComponent) for Lime.")
        }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let bundle = bundles.first(where: { $0.pathExtension == "qlpreview" }) else {
            throw LimeError("macOS has no preview for \(source.lastPathComponent), so it cannot be converted.")
        }
        let html = bundle.appendingPathComponent("Preview.html")
        let files = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []
        let attachments = files.filter { $0.lastPathComponent.hasPrefix("Attachment") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard FileManager.default.fileExists(atPath: html.path) || !attachments.isEmpty else {
            throw LimeError("macOS returned an empty preview for \(source.lastPathComponent).")
        }
        return Preview(html: html, attachments: attachments)
    }

    /// A presentation as a PDF with one page per slide.
    static func slidesPDF(_ source: URL, to destination: URL, workspace: URL) async throws {
        let preview = try await preview(source, workspace: workspace)
        let document = try await SlideSnapshotter.render(html: preview.html)
        guard document.pageCount > 0 else { throw LimeError("No slides were found in \(source.lastPathComponent).") }
        guard document.write(to: destination) else { throw LimeError("The PDF could not be saved.") }
    }

    /// An iWork document as the PDF its Quick Look generator lays out.
    static func documentPDF(_ source: URL, workspace: URL) async throws -> PDFDocument {
        let preview = try await preview(source, workspace: workspace)
        if let pdf = preview.pdf, let document = PDFDocument(url: pdf), document.pageCount > 0 { return document }
        let document = try await SlideSnapshotter.render(html: preview.html, selector: "body")
        guard document.pageCount > 0 else { throw LimeError("Lime couldn't draw \(source.lastPathComponent).") }
        return document
    }
}

/// Loads a Quick Look HTML preview off screen and prints each slide element
/// as one PDF page.
@MainActor
final class SlideSnapshotter: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?

    private init(width: CGFloat) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    /// Slides keep their own size: margins and shadows of the preview are removed.
    private static let flatten = """
    (function(){var s=document.createElement('style');s.textContent=
    'body{margin:0!important;background:#fff!important}div.slide{margin:0!important;-webkit-box-shadow:none!important;box-shadow:none!important}div.loading-slide{display:none!important}';
    document.head.appendChild(s);})();
    """

    static func render(html: URL, selector: String = "div.slide") async throws -> PDFDocument {
        let snapshotter = SlideSnapshotter(width: 1600)
        try await snapshotter.load(html)
        _ = try await snapshotter.web.evaluateJavaScript(flatten)
        try await Task.sleep(nanoseconds: 300_000_000)
        let script = """
        JSON.stringify(Array.from(document.querySelectorAll('\(selector)')).map(function(e){
          var r=e.getBoundingClientRect();return [r.left+window.scrollX,r.top+window.scrollY,Math.max(r.width,e.scrollWidth),Math.max(r.height,e.scrollHeight)];}))
        """
        let json = try await snapshotter.web.evaluateJavaScript(script) as? String ?? "[]"
        let rects = (try? JSONDecoder().decode([[Double]].self, from: Data(json.utf8))) ?? []
        let document = PDFDocument()
        for rect in rects where rect.count == 4 && rect[2] > 1 && rect[3] > 1 {
            try Task.checkCancellation()
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
            let data = try await snapshotter.web.pdf(configuration: configuration)
            if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) }
        }
        return document
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
}
