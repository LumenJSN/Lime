import Foundation
import ImageIO

/// Still-image conversion between the picture formats.
enum ImageConverter {
    static func convert(_ source: URL, to format: String, context: OperationContext) async throws {
        let options = context.optionsForFormat(format)
        guard ImageIOKit.canWrite(format) else { throw LimeError("Lime has no encoder for \(FormatCatalog.label(format)).") }
        let destination = context.output(for: source, ext: format)
        if format == "pdf" {
            try ImageIOKit.writePDF([ImageIOKit.pdfImage(source)], to: destination, dpi: ImageIOKit.pixelDPI(source))
            return
        }
        let image = try ImageIOKit.load(source)
        let metadata = options.keepTags ? ImageIOKit.portableMetadata(source) : [:]
        try await ImageIOKit.write(image, to: destination, format: format, quality: options.quality,
                                   metadata: metadata, pngLevel: options.compressionLevel)
    }
}
