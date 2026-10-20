import Foundation

/// Audio, video and GIF format conversion through the bundled ffmpeg.
enum MediaConverter {
    static func convert(_ source: URL, to format: String, context: OperationContext) async throws {
        let options = context.optionsForFormat(format)
        let info = try await FFmpeg.probe(source)
        let destination = context.output(for: source, ext: format)
        var args = ["-i", source.path] + FFmpeg.metadataArguments(preserve: options.keepTags)
        if FormatCatalog.audio.contains(format) {
            guard info.hasAudio else { throw LimeError("Lime can't find any sound to play in this file.") }
            args += ["-map", "0:a:0", "-vn"] + FFmpeg.audioCodec(format, options: options, info: info)
        } else if format == "gif" {
            guard info.hasVideo else { throw LimeError("Lime can't find any picture in this file.") }
            let width = min(info.width > 0 ? info.width : options.gifWidthCap, options.gifWidthCap)
            let fps = options.gifFPS
            args += ["-an", "-filter_complex",
                     "[0:v:0]fps=\(fps),scale=\(width):-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a",
                     "-loop", "0"]
        } else {
            guard info.hasVideo else { throw LimeError("Lime can't find any picture in this file.") }
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", FFmpeg.scaleFilter(options: options, info: info)]
            args += FFmpeg.videoCodec(format, options: options, info: info)
        }
        args.append(destination.path)
        try await FFmpeg.run(args, duration: info.duration, context: context)
    }
}
