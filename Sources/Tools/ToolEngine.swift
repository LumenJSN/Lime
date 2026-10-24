import Foundation

/// Runs a file tool over a selection and publishes its outputs.
enum ToolEngine {
    static func run(_ tool: LimeTool, files: [URL], options: ToolChoices, context: OperationContext) async throws -> [URL] {
        guard !files.isEmpty else { throw LimeError("Nothing was dropped") }
        if tool.isAggregate {
            try await runAggregate(tool, files: files, options: options, context: context)
        } else {
            let categories = files.map { FormatCatalog.category(FormatCatalog.format(of: $0) ?? "") }
            // Background removal holds a large Vision model per file.
            let limit = tool == .removeBackground ? min(2, Parallelism.limit(for: categories)) : Parallelism.limit(for: categories)
            try await context.forEach(files, limit: limit) { _, file in
                try await runSingle(tool, file: file, options: options, context: context)
                context.progress(1)
            }
        }
        return try OutputPublisher.publish(context.stagedOutputs)
    }

    private static func runAggregate(_ tool: LimeTool, files: [URL], options: ToolChoices, context: OperationContext) async throws {
        switch tool {
        case .imagesToPDF: try await ImageTools.imagesToPDF(files, options: options, context: context)
        case .makeMosaic: try await ImageTools.collage(files, options: options, context: context)
        case .combinePDFs: try PDFTools.merge(files, options: options, context: context)
        case .stitchVideos: try await MediaTools.join(files, options: options, context: context)
        default: break
        }
    }

    private static func runSingle(_ tool: LimeTool, file: URL, options: ToolChoices, context: OperationContext) async throws {
        let category = FormatCatalog.category(FormatCatalog.format(of: file) ?? "")
        switch tool {
        case .compress:
            switch category {
            case .image: try await ImageTools.compress(file, options: options, context: context)
            case .pdf: try await PDFTools.compress(file, options: options, context: context)
            default: try await MediaTools.compress(file, options: options, context: context)
            }
        case .stripTags: try await MetadataTools.apply(file, options: options, context: context)
        case .adjustPhoto: try await ImageTools.edit(file, options: options, context: context)
        case .markUpPhoto: try await ImageTools.annotate(file, options: options, context: context)
        case .addBackdrop: try await ImageTools.frame(file, options: options, context: context)
        case .cropPhoto: try await ImageTools.crop([file], options: options, context: context)
        case .maskPhoto: try await ImageTools.redact(file, options: options, context: context)
        case .levelAudio: try await MediaTools.normalize(file, options: options, context: context)
        case .silenceVideo: try await MediaTools.mute(file, context: context)
        case .cutVideo, .cutAudio: try await MediaTools.trim(file, options: options, context: context)
        case .cropClip: try await MediaTools.cropClip(file, options: options, context: context)
        case .retimeVideo: try await MediaTools.speed(file, options: options, context: context)
        case .grabFrames: try await MediaTools.snapshots(file, options: options, context: context)
        case .sliceVideo: try await MediaTools.split(file, options: options, context: context)
        case .waveVideo: try await MediaTools.visualize(file, options: options, context: context)
        case .remixChannels: try await MediaTools.channels(file, options: options, context: context)
        case .maskVideo: try await MediaTools.maskVideo(file, options: options, context: context)
        case .censorAudio: try await MediaTools.bleep(file, options: options, context: context)
        case .splitPages: try PDFTools.split(file, context: context)
        case .arrangePages: try PDFTools.organize(file, options: options, context: context)
        case .unpackArchive:
            let folder = try context.outputFolder(for: file, label: "extracted")
            try await ArchiveTranscoder.extract(file, into: folder)
        case .removeBackground: try await BackgroundRemoval.run(file, context: context)
        case .scanQR, .copyText, .imagesToPDF, .combinePDFs, .stitchVideos, .makeMosaic:
            break
        }
    }
}
