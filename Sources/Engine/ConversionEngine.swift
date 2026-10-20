import Foundation

/// Routes a conversion to the engine for its source category.
enum ConversionEngine {
    static func convert(_ files: [URL], to target: String, context: OperationContext) async throws -> [URL] {
        guard !files.isEmpty else { throw LimeError("Nothing was dropped") }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let format = FormatCatalog.format(of: file), FormatCatalog.targets(for: format).contains(target) else {
                throw LimeError("Lime can't turn \(file.lastPathComponent) into \(FormatCatalog.label(target)).")
            }
            let span = (Double(index) / Double(files.count))...(Double(index + 1) / Double(files.count))
            context.progressSpan = span
            do {
                try await convert(file, from: format, to: target, context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LimeError(files.count > 1 ? "\(file.lastPathComponent): \(error.localizedDescription)" : error.localizedDescription)
            }
        }
        context.progressSpan = 0...1
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
