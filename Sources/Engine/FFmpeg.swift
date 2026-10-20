import Foundation

/// Stream facts from ffprobe, used by encoders and tool editors.
struct MediaProbe: Sendable {
    var duration: Double = 0
    var hasVideo = false
    var hasAudio = false
    var width = 0
    var height = 0
    var frameRate: Double = 30
    var videoBitrate: Int = 0
    var encodeKbps: Int = 0
    var remixChannels = 0
    var sampleRate = 0
    var bitsPerSample = 0
    var sampleFormat = ""
    var tags: [String: String] = [:]
}

enum FFmpeg {
    static func probe(_ url: URL) async throws -> MediaProbe {
        let tool = try BundledTool.url("ffprobe")
        let result = try await ProcessRunner.run(tool, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw LimeError("Lime couldn't tell how long \(url.lastPathComponent) is.")
        }
        var info = MediaProbe()
        let format = json["format"] as? [String: Any] ?? [:]
        info.duration = Double(format["duration"] as? String ?? "") ?? 0
        if let tags = format["tags"] as? [String: String] { info.tags = tags.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value } }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let kind = stream["codec_type"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            if kind == "video", (disposition?["attached_pic"] as? Int ?? 0) == 0, !info.hasVideo {
                info.hasVideo = true
                var w = stream["width"] as? Int ?? 0, h = stream["height"] as? Int ?? 0
                let sideData = stream["side_data_list"] as? [[String: Any]] ?? []
                let rotation = sideData.compactMap { $0["rotation"] as? Int }.first ?? Int((stream["tags"] as? [String: String])?["rotate"] ?? "0") ?? 0
                if abs(rotation) % 180 == 90 { swap(&w, &h) }
                info.width = w; info.height = h
                info.videoBitrate = Int(stream["bit_rate"] as? String ?? "") ?? 0
                if let rate = stream["avg_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0, parts[0] > 0 { info.frameRate = parts[0] / parts[1] }
                }
                if info.duration == 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            } else if kind == "audio", !info.hasAudio {
                info.hasAudio = true
                info.remixChannels = stream["channels"] as? Int ?? 0
                info.sampleRate = Int(stream["sample_rate"] as? String ?? "") ?? 0
                info.encodeKbps = Int(stream["bit_rate"] as? String ?? "") ?? 0
                info.bitsPerSample = Int(stream["bits_per_raw_sample"] as? String ?? "") ?? (stream["bits_per_sample"] as? Int ?? 0)
                info.sampleFormat = stream["sample_fmt"] as? String ?? ""
                if info.duration == 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            }
        }
        if info.videoBitrate == 0, info.hasVideo, info.duration > 0,
           let total = Int(format["bit_rate"] as? String ?? "") { info.videoBitrate = max(0, total - info.encodeKbps) }
        return info
    }

    /// Runs ffmpeg and maps `-progress` timestamps onto 0…1.
    static func run(_ arguments: [String], duration: Double, context: OperationContext?, span: ClosedRange<Double> = 0...1) async throws {
        let tool = try BundledTool.url("ffmpeg")
        let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-progress", "pipe:1", "-nostats"] + arguments
        try await ProcessRunner.run(tool, args, onOutput: { text in
            guard let context, duration > 0 else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let micro = Double(line.dropFirst(12)) {
                    let fraction = min(1, max(0, micro / 1_000_000 / duration))
                    context.progress(span.lowerBound + (span.upperBound - span.lowerBound) * fraction)
                }
            }
        })
    }

    static func metadataArguments(preserve: Bool) -> [String] {
        ["-map_metadata", preserve ? "0" : "-1", "-map_chapters", preserve ? "0" : "-1"]
    }

    /// PCM codec for WAV/AIFF at the chosen bit depth; "Match source" keeps
    /// float audio as float and otherwise rounds up to 16, 24 or 32 bits.
    static func pcmCodec(bigEndian: Bool, depth: ConvertPrefs.BitDepth, info: MediaProbe?) -> String {
        var depth = depth
        if depth == .source {
            let source = info?.sampleFormat ?? "", bits = info?.bitsPerSample ?? 0
            depth = source.hasPrefix("flt") || source.hasPrefix("dbl") ? .float32 : bits > 24 ? .int32 : bits > 16 ? .int24 : .int16
        }
        let suffix = bigEndian ? "be" : "le"
        switch depth {
        case .int24: return "pcm_s24" + suffix
        case .int32: return "pcm_s32" + suffix
        case .float32: return "pcm_f32" + suffix
        default: return "pcm_s16" + suffix
        }
    }

    /// Codec arguments for an audio-only output.
    static func audioCodec(_ format: String, options: ConvertPrefs, bitrateOverride: Int? = nil, info: MediaProbe? = nil) -> [String] {
        let kbps = min(320, max(32, bitrateOverride ?? options.encodeKbps))
        switch format {
        case "mp3": return ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        case "m4a": return ["-c:a", "aac_at", "-b:a", "\(kbps)k", "-movflags", "+faststart"]
        case "wav": return ["-c:a", pcmCodec(bigEndian: false, depth: options.bitDepth, info: info)]
        case "aiff": return ["-c:a", pcmCodec(bigEndian: true, depth: options.bitDepth, info: info), "-write_id3v2", "1"]
        case "flac":
            let level = options.effort == .faster ? 1 : options.effort == .smallest ? 12 : 5
            let deep = (info?.bitsPerSample ?? 16) > 16 || (info?.sampleFormat ?? "").hasPrefix("flt") || (info?.sampleFormat ?? "").hasPrefix("s32")
            return ["-c:a", "flac", "-compression_level", String(level), "-sample_fmt", deep ? "s32" : "s16"] + (deep ? ["-bits_per_raw_sample", "24"] : [])
        case "ogg": return ["-c:a", "libvorbis", "-b:a", "\(kbps)k"]
        case "opus": return ["-c:a", "libopus", "-b:a", "\(min(256, kbps))k", "-ar", "48000"]
        case "wma": return ["-c:a", "wmav2", "-b:a", "\(min(256, kbps))k", "-ar", "44100"]
        case "aac": return ["-c:a", "aac_at", "-b:a", "\(kbps)k"]
        default: return []
        }
    }

    /// Video+audio codec arguments for a container.
    static func videoCodec(_ format: String, options: ConvertPrefs, info: MediaProbe, videoKbps: Int? = nil, audioKbps: Int = 192) -> [String] {
        let q = options.quality
        let pixels = Double(max(1, info.width * info.height))
        let estimated = Int(pixels * min(60, max(1, info.frameRate)) * (0.04 + 0.12 * q) / 1000)
        let kbps = videoKbps ?? max(400, estimated)
        switch format {
        case "mp4", "mov", "mkv":
            var args = ["-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "\(kbps)k", "-maxrate", "\(Int(Double(kbps) * 1.5))k",
                        "-pix_fmt", "yuv420p", "-c:a", "aac_at", "-b:a", "\(audioKbps)k"]
            if format == "mov" { args += ["-tag:v", "avc1"] }
            if format != "mkv" { args += ["-movflags", "+faststart"] }
            return args
        case "webm":
            let crf = videoKbps == nil ? ["-crf", String(Int(44 - q * 22)), "-b:v", "0"] : ["-b:v", "\(kbps)k"]
            return ["-c:v", "libvpx-vp9"] + crf + ["-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "\(min(256, audioKbps))k"]
        case "avi": return ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", String(max(1, Int(12 - q * 10))), "-pix_fmt", "yuv420p", "-c:a", "libmp3lame", "-b:a", "\(min(320, audioKbps))k"]
        case "wmv": return ["-c:v", "wmv2", "-b:v", "\(kbps)k", "-pix_fmt", "yuv420p", "-c:a", "wmav2", "-b:a", "\(min(192, audioKbps))k", "-ar", "44100"]
        default: return []
        }
    }

    /// Even dimensions plus the optional maximum height.
    static func scaleFilter(options: ConvertPrefs, info: MediaProbe) -> String {
        if options.maxVideoHeight > 0, info.height > options.maxVideoHeight {
            return "scale=-2:\(options.maxVideoHeight)"
        }
        return "pad=ceil(iw/2)*2:ceil(ih/2)*2"
    }

    static func timestamp(_ seconds: Double) -> String { String(format: "%.3f", max(0, seconds)) }
}
