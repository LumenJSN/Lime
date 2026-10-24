import Foundation

/// Decides which streams can move into the new container untouched. Copying
/// skips decoding and encoding entirely, so it is many times faster and loses
/// nothing; only streams the target plays back reliably are copied.
enum StreamCopy {
    struct Plan: Equatable {
        var video: Bool
        var audio: Bool
    }

    /// Video codecs, with the pixel formats each container takes as is.
    private static let videoCodecs: [String: [String: Set<String>]] = [
        "mp4": ["h264": ["yuv420p", "yuvj420p"], "hevc": ["yuv420p", "yuvj420p", "yuv420p10le"]],
        "mov": ["h264": ["yuv420p", "yuvj420p"], "hevc": ["yuv420p", "yuvj420p", "yuv420p10le"]],
        "mkv": ["h264": ["yuv420p", "yuvj420p"], "hevc": ["yuv420p", "yuvj420p", "yuv420p10le"],
                "vp9": ["yuv420p", "yuv420p10le"], "av1": ["yuv420p", "yuv420p10le"]],
    ]

    /// Audio codecs each target takes without re-encoding.
    private static let audioCodecs: [String: Set<String>] = [
        "mp4": ["aac", "mp3"], "mov": ["aac", "mp3"], "mkv": ["aac", "mp3", "opus", "vorbis", "flac", "ac3"],
        "m4a": ["aac"], "aac": ["aac"], "mp3": ["mp3"], "ogg": ["vorbis"], "opus": ["opus"], "flac": ["flac"],
    ]

    static func plan(_ info: MediaProbe, into format: String, options: ConvertPrefs) -> Plan {
        let scaled = options.maxVideoHeight > 0 && info.height > options.maxVideoHeight
        // "Smaller File" asks for a smaller file, which only an encode gives.
        // AVI stores no display times, so copied B-frames would play out of order.
        let video = info.hasVideo && !scaled && options.qualityPreset != .smaller && info.container != "avi"
            && videoCodecs[format]?[info.videoCodec]?.contains(info.pixelFormat) == true
        // AAC and MP3 start with encoder warm-up samples that MP4 and Matroska
        // mark in different ways; moved across, they play as a short gap.
        let sameTiming = info.audioCodec == "flac" || family(ofContainer: info.container) == family(ofTarget: format)
        // A tenth of headroom keeps audio encoded at the chosen rate, which runs a
        // little over it, from being encoded again. An unknown rate is encoded.
        let withinBitrate = !FormatCatalog.audio.contains(format) || (info.encodeKbps > 0 && info.encodeKbps <= options.encodeKbps * 1100)
        let audio = info.hasAudio && sameTiming && withinBitrate && audioCodecs[format]?.contains(info.audioCodec) == true
        return Plan(video: video, audio: audio)
    }

    /// Containers that record audio timing the same way.
    private static func family(ofContainer name: String) -> String {
        if name.contains("matroska") || name.contains("webm") { return "mkv" }
        if name.contains("mp4") || name.contains("mov") { return "mp4" }
        return name
    }

    private static func family(ofTarget format: String) -> String {
        switch format {
        case "mkv": "mkv"
        case "mp4", "mov", "m4a": "mp4"
        case "ogg", "opus": "ogg"
        default: format
        }
    }

    /// Clips whose pictures can be joined into an MP4 back to back without
    /// re-encoding: same container, codec, picture size, frame rate and
    /// sound layout. Mixed containers keep time differently and come apart.
    /// The joined file keeps the first clip's clock units, track order and
    /// decoder setup, so those must match too, and a clip trimmed in an
    /// editor would bring back the frames it hides.
    static func canJoin(_ clips: [MediaProbe]) -> Bool {
        guard let first = clips.first, clips.count >= 2, plan(first, into: "mp4", options: ConvertPrefs()).video else { return false }
        return clips.allSatisfy {
            $0.hasVideo && $0.container == first.container && $0.videoCodec == first.videoCodec && $0.pixelFormat == first.pixelFormat
                && $0.width == first.width && $0.height == first.height && $0.rotation == first.rotation && abs($0.frameRate - first.frameRate) < 0.01
                && $0.hasAudio == first.hasAudio && $0.audioCodec == first.audioCodec
                && $0.sampleRate == first.sampleRate && $0.remixChannels == first.remixChannels
                && $0.videoTimeBase == first.videoTimeBase && $0.streamKinds == first.streamKinds && $0.videoExtradata == first.videoExtradata
                && !hidesFrames($0)
        }
    }

    /// More frames stored than the picture shows: an edit list cuts some off.
    private static func hidesFrames(_ clip: MediaProbe) -> Bool {
        clip.videoFrames > 0 && clip.videoDuration > 0 && Double(clip.videoFrames) > clip.videoDuration * clip.frameRate + 2
    }

    /// QuickTime only plays HEVC in MP4 and MOV under the `hvc1` tag.
    static func videoTag(_ codec: String, into format: String) -> [String] {
        codec == "hevc" && format != "mkv" ? ["-tag:v", "hvc1"] : []
    }
}
