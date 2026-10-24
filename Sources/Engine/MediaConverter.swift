import Foundation

/// Audio, video and GIF format conversion through the bundled ffmpeg.
enum MediaConverter {
    static func convert(_ source: URL, to format: String, context: OperationContext) async throws {
        let options = context.optionsForFormat(format)
        let info = try await FFmpeg.probe(source)
        let destination = context.output(for: source, ext: format)
        var args = ["-i", source.path] + FFmpeg.metadataArguments(preserve: options.keepTags)
        let copy = StreamCopy.plan(info, into: format, options: options)
        if format != "gif", FormatCatalog.audio.contains(format) ? copy.audio : copy.video {
            // Streams the new container takes as they are; fall back to a full
            // encode if ffmpeg turns the copy down (odd timestamps and the like).
            do {
                try await FFmpeg.run(args + copyArguments(copy, info: info, format: format, options: options) + [destination.path],
                                     duration: info.duration, context: context)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        }
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

    /// Stream maps and codecs for a conversion that copies what it can.
    static func copyArguments(_ copy: StreamCopy.Plan, info: MediaProbe, format: String, options: ConvertPrefs) -> [String] {
        if FormatCatalog.audio.contains(format) {
            guard info.hasAudio else { return [] }
            return ["-map", "0:a:0", "-vn"] + (copy.audio ? ["-c:a", "copy"] : FFmpeg.audioCodec(format, options: options, info: info))
        }
        guard copy.video else { return [] }
        var args = ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"] + StreamCopy.videoTag(info.videoCodec, into: format)
        if info.hasAudio { args += copy.audio ? ["-c:a", "copy"] : ["-c:a", "aac_at", "-b:a", "192k"] }
        if format != "mkv" { args += ["-movflags", "+faststart"] }
        return args
    }
}
