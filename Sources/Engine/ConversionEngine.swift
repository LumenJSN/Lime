import Foundation

/// Routes a conversion to the engine for its source category.
enum ConversionEngine {
    static func convert(_ files: [URL], to target: String, context: OperationContext) async throws -> [URL] {
        guard !files.isEmpty else { throw LimeError("Nothing was dropped") }
        let formats = try files.map { file -> String in
            guard let format = FormatCatalog.format(of: file), FormatCatalog.targets(for: format).contains(target) else {
                throw LimeError("Lime can't turn \(file.lastPathComponent) into \(FormatCatalog.label(target)).")
            }
            return format
        }
        try await context.forEach(files, limit: Parallelism.limit(for: formats.map(FormatCatalog.category))) { index, file in
            try await convert(file, from: formats[index], to: target, context: context)
            context.progress(1)
        }
        return try OutputPublisher.publish(context.stagedOutputs)
    }

    static func convert(_ file: URL, from format: String, to target: String, context: OperationContext) async throws {
        switch FormatCatalog.category(format) {
        case .image:
            try await ImageConverter.convert(file, to: target, context: context)
        case .audio, .video:
            try await MediaConverter.convert(file, to: target, context: context)
        case .pdf:
            try await PDFConverter.convert(file, to: target, context: context)
        case .slides:
            try await SlidesConverter.convert(file, to: target, context: context)
        case .spreadsheet:
            try await SpreadsheetIO.convert(file, from: format, to: target, context: context)
        case .document:
            try await DocTranscoder.convert(file, from: format, to: target, context: context)
        case .subtitle:
            try CaptionTranscoder.convert(file, to: target, context: context)
        case .archive:
            try await ArchiveTranscoder.convert(file, to: target, context: context)
        case nil:
            throw LimeError("Unknown kind of file")
        }
    }
}
