import Foundation
import PDFKit
import Vision

/// Grab Text: on-device text recognition with Vision.
/// PDFs use their text layer when present and OCR for scanned pages.
enum TextRecognition {
    /// Languages tried first; Vision also detects others automatically.
    static let preferredLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans", "zh-Hant"]
    /// Below this many characters a PDF page counts as scanned.
    private static let textLayerMinimum = 20

    static func text(in url: URL) throws -> String {
        guard FormatCatalog.format(of: url) == "pdf" else { return try recognize(ImageIOKit.load(url)) }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw LimeError("This PDF is unreadable, blank or locked.")
        }
        let pages = try (0..<document.pageCount).compactMap { index -> String? in
            guard let page = document.page(at: index) else { return nil }
            let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if layer.count >= textLayerMinimum { return layer }
            return try recognize(DocumentRenderer.pageImage(page, dpi: 200))
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        request.recognitionLanguages = preferredLanguages.filter(supported.contains)
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return lines(request.results ?? []).joined(separator: "\n")
    }

    /// Joins observations that share a baseline into one line, top to bottom.
    static func lines(_ observations: [VNRecognizedTextObservation]) -> [String] {
        let items = observations.compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
        var rows: [(box: CGRect, parts: [(x: CGFloat, text: String)])] = []
        for item in items.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let i = rows.firstIndex(where: { abs($0.box.midY - item.box.midY) < min($0.box.height, item.box.height) * 0.5 }) {
                rows[i].parts.append((item.box.minX, item.text))
                rows[i].box = rows[i].box.union(item.box)
            } else {
                rows.append((item.box, [(item.box.minX, item.text)]))
            }
        }
        return rows.map { $0.parts.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }
}
