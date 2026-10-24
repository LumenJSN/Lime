import Foundation

/// Audio and video tools built on the bundled ffmpeg.
enum MediaTools {
    static func format(_ url: URL) -> String { FormatCatalog.format(of: url) ?? "mp4" }
    static func isAudio(_ url: URL) -> Bool { FormatCatalog.audio.contains(format(url)) }

    /// Re-encode arguments that keep the source container and codec family.
    static func codecArguments(for url: URL, info: MediaProbe, context: OperationContext, videoKbps: Int? = nil, audioKbps: Int? = nil) -> [String] {
        let fmt = format(url)
        let options = context.optionsForFormat(fmt)
        if FormatCatalog.audio.contains(fmt) { return FFmpeg.audioCodec(fmt, options: options, bitrateOverride: audioKbps) }
        return FFmpeg.videoCodec(fmt, options: options, info: info, videoKbps: videoKbps, audioKbps: audioKbps ?? 192)
    }

    // MARK: Compress

    static func compress(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard info.duration > 0 else { throw LimeError("This file has no length to work with.") }
        let fmt = format(source)
        let original = ImageTools.fileSize(source)
        let outFormat = fmt == "wav" ? "flac" : fmt
        let output = context.output(for: source, label: "compressed", ext: outFormat)
        let target = options.targetBytes(original: original)
        if let target, target >= original { throw LimeError("The target has to be smaller than the file is now.") }
        let base = ["-i", source.path] + FFmpeg.metadataArguments(preserve: true)
        if isAudio(source) {
            var kbps: Int?
            if let target {
                kbps = Int(Double(target) * 8 / info.duration / 1000 * 0.97)
                guard (kbps ?? 0) >= 16 else { throw LimeError("That's too small for a clip this long. Try a bigger target.") }
            } else if !["flac", "wav", "aiff"].contains(fmt) {
                let current = max(64, info.encodeKbps / 1000)
                kbps = options.squashLevel == .gentle ? max(64, Int(Double(current) * 0.6)) : max(48, Int(Double(current) * 0.4))
            }
            var opts = context.optionsForFormat(outFormat); opts.compressionLevel = 9
            var codec = FFmpeg.audioCodec(outFormat, options: opts, bitrateOverride: kbps)
            if outFormat == "aiff" { codec = ["-c:a", "pcm_s16be"] }
            if fmt == "flac" || fmt == "wav" { codec += ["-sample_fmt", "s16"] }
            try await FFmpeg.run(base + ["-map", "0:a", "-vn"] + codec + [output.path], duration: info.duration, context: context)
        } else {
            guard info.hasVideo else { throw LimeError("Lime can't find any picture in this file.") }
            var audioKbps = info.hasAudio ? 128 : 0
            var videoKbps: Int
            if let target {
                let totalKbps = Int((Double(target) * 8 / info.duration / 1000) * 0.95)
                if info.hasAudio { audioKbps = min(128, max(48, totalKbps / 6)) }
                videoKbps = totalKbps - audioKbps
                guard videoKbps >= 80 else { throw LimeError("Once the sound fits, there's no room left for picture.") }
            } else {
                let current = max(500, info.videoBitrate / 1000)
                videoKbps = Int(Double(current) * (options.squashLevel == .gentle ? 0.5 : 0.28))
            }
            var scale = FFmpeg.scaleFilter(options: ConvertPrefs(), info: info)
            if options.squashLevel == .hard, target == nil, info.height > 1080 { scale = "scale=-2:1080" }
            func encode(_ kbps: Int) async throws {
                try await FFmpeg.run(base + ["-map", "0:v:0", "-map", "0:a?", "-vf", scale]
                    + codecArguments(for: source, info: info, context: context, videoKbps: kbps, audioKbps: max(48, audioKbps)) + [output.path],
                    duration: info.duration, context: context)
            }
            try await encode(videoKbps)
            if let target, options.videoFitPass == .accurate {
                // Second pass corrects for rate-control overshoot.
                for _ in 0..<2 where ImageTools.fileSize(output) > target {
                    let ratio = Double(target) / Double(ImageTools.fileSize(output))
                    videoKbps = Int(Double(videoKbps) * ratio * 0.95)
                    guard videoKbps >= 80 else { throw LimeError("This clip won't fit in that size. Try a bigger target.") }
                    try await encode(videoKbps)
                }
                if ImageTools.fileSize(output) > target { throw LimeError("This clip won't fit in that size. Try a bigger target.") }
            }
        }
        if target == nil, ImageTools.fileSize(output) >= original, fmt != "wav" {
            throw LimeError("Compressing wouldn't make this file any smaller than it already is.")
        }
    }

    // MARK: Simple edits

    static func mute(_ source: URL, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard info.hasVideo else { throw LimeError("Only clips with picture can be joined.") }
        let out = context.output(for: source, label: "muted", ext: format(source))
        try await FFmpeg.run(["-i", source.path, "-map", "0:v", "-map", "0:s?", "-c", "copy", "-an", "-map_metadata", "0", out.path], duration: info.duration, context: context)
    }

    static func normalize(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard info.hasAudio else { throw LimeError("This file has no sound.") }
        let i = options.levelTargetLUFS, lra = options.levelRangeLU, tp = options.levelPeakDB
        let ffmpeg = try BundledTool.url("ffmpeg")
        // Pass 1 measures. ebur128 is several times quicker than loudnorm, and
        // most audio only needs its volume turned, which costs next to nothing.
        let quick = try await ProcessRunner.run(ffmpeg, FFmpeg.guarded(["-nostdin", "-hide_banner", "-nostats", "-i", source.path, "-vn",
                                                         "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"]))
        let filter: String
        if let measure = Loudness.parse(quick.stderr), let gain = Loudness.linearGain(measure, target: i, range: lra, peak: tp) {
            filter = String(format: "volume=%.1fdB", gain)
        } else {
            filter = try await loudnormFilter(source, ffmpeg: ffmpeg, target: i, range: lra, peak: tp)
        }
        context.progress(0.4)
        let out = context.output(for: source, label: "normalized", ext: format(source))
        let sampleRate = info.sampleRate > 0 ? info.sampleRate : 48000
        var args = ["-i", source.path] + FFmpeg.metadataArguments(preserve: true)
        if isAudio(source) {
            args += ["-map", "0:a:0", "-af", filter, "-ar", "\(sampleRate)"] + codecArguments(for: source, info: info, context: context)
        } else {
            args += ["-map", "0:v?", "-map", "0:a:0", "-c:v", "copy", "-af", filter, "-ar", "\(sampleRate)", "-c:a", "aac_at", "-b:a", "192k"]
        }
        try await FFmpeg.run(args + [out.path], duration: info.duration, context: context, span: 0.4...1)
    }

    /// loudnorm's own measurement, fed back for an accurate dynamic second pass.
    private static func loudnormFilter(_ source: URL, ffmpeg: URL, target i: Double, range lra: Double, peak tp: Double) async throws -> String {
        let measure = try await ProcessRunner.run(ffmpeg, FFmpeg.guarded(["-nostdin", "-hide_banner", "-i", source.path, "-vn", "-af",
                                                           "loudnorm=I=\(i):LRA=\(lra):TP=\(tp):print_format=json", "-f", "null", "-"]))
        var filter = "loudnorm=I=\(i):LRA=\(lra):TP=\(tp)"
        if let json = Loudness.loudnormReport(measure.stderr), let mi = json["input_i"], let mlra = json["input_lra"], let mtp = json["input_tp"], let mth = json["input_thresh"], let off = json["target_offset"] {
            filter += ":measured_I=\(mi):measured_LRA=\(mlra):measured_TP=\(mtp):measured_thresh=\(mth):offset=\(off):linear=true"
        }
        return filter
    }

    static func trim(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        var start = max(0, options.cutStart)
        var duration = options.cutLength > 0 ? options.cutLength : info.duration - start
        guard start < info.duration, duration > 0.01 else { throw LimeError("The cut has to start and end inside the file.") }
        duration = min(duration, info.duration - start)
        let out = context.output(for: source, label: "trimmed", ext: format(source))
        var args = ["-ss", FFmpeg.timestamp(start), "-t", FFmpeg.timestamp(duration), "-i", source.path] + FFmpeg.metadataArguments(preserve: true)
        if isAudio(source) {
            args += ["-map", "0:a:0"]
            if options.dropSilentEnds {
                let t = options.silenceFloorDB
                args += ["-af", "silenceremove=start_periods=1:start_threshold=\(t)dB:start_silence=0.05,areverse,silenceremove=start_periods=1:start_threshold=\(t)dB:start_silence=0.05,areverse"]
            }
            args += codecArguments(for: source, info: info, context: context)
        } else {
            args += ["-map", "0:v:0", "-map", "0:a?", "-vf", FFmpeg.scaleFilter(options: ConvertPrefs(), info: info)] + codecArguments(for: source, info: info, context: context)
        }
        start = 0
        try await FFmpeg.run(args + [out.path], duration: duration, context: context)
    }

    static func cropClip(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard let r = options.cropRect, info.width > 0 else { throw LimeError("The crop has to stay inside the picture.") }
        let w = max(2, Int(r.width * Double(info.width)) / 2 * 2), h = max(2, Int(r.height * Double(info.height)) / 2 * 2)
        let x = Int(r.minX * Double(info.width)), y = Int(r.minY * Double(info.height))
        guard x >= 0, y >= 0, x + w <= info.width + 1, y + h <= info.height + 1 else { throw LimeError("The crop has to stay inside the picture.") }
        var cropped = info; cropped.width = w; cropped.height = h
        let kbps = info.videoBitrate > 0 ? max(400, Int(Double(info.videoBitrate / 1000) * Double(w * h) / Double(max(1, info.width * info.height)) * 1.1)) : nil
        let out = context.output(for: source, label: "cropped", ext: format(source))
        var args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-vf", "crop=\(w):\(h):\(x):\(y)"] + FFmpeg.metadataArguments(preserve: true)
        args += codecArguments(for: source, info: cropped, context: context, videoKbps: kbps)
        if ["mp4", "mov", "mkv"].contains(format(source)) { args += ["-c:a", "copy"] }
        try await FFmpeg.run(args + [out.path], duration: info.duration, context: context)
    }

    static func speed(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let s = options.tempoFactor
        guard s >= 0.25, s <= 4 else { throw LimeError("Speed has to be from 0.25× to 4×.") }
        let info = try await FFmpeg.probe(source)
        var tempo: [String] = [], remaining = s
        while remaining > 2 { tempo.append("atempo=2.0"); remaining /= 2 }
        while remaining < 0.5 { tempo.append("atempo=0.5"); remaining /= 0.5 }
        tempo.append(String(format: "atempo=%.4f", remaining))
        let label = "Speed " + (s == s.rounded() ? String(Int(s)) : String(format: "%g", s)) + "x"
        let out = context.output(for: source, label: label, ext: format(source))
        var args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-filter:v", String(format: "setpts=PTS/%.4f", s)]
        if info.hasAudio { args += ["-filter:a", tempo.joined(separator: ",")] }
        args += FFmpeg.metadataArguments(preserve: true) + codecArguments(for: source, info: info, context: context)
        try await FFmpeg.run(args + [out.path], duration: info.duration / s, context: context)
    }

    static func join(_ sources: [URL], options: ToolChoices, context: OperationContext) async throws {
        let ordered = options.orderedFiles ?? sources
        guard ordered.count >= 2 else { throw LimeError("Joining needs two or more videos.") }
        var infos: [MediaProbe] = []
        for url in ordered { infos.append(try await FFmpeg.probe(url)) }
        guard infos.allSatisfy(\.hasVideo) else { throw LimeError("Only clips with picture can be joined.") }
        if StreamCopy.canJoin(infos), try await joinCopying(ordered, infos: infos, context: context) { return }
        let w = infos[0].width / 2 * 2, h = infos[0].height / 2 * 2
        let fps = min(60, max(10, infos[0].frameRate))
        let spans = pictureSpans(infos)
        var inputs: [String] = [], filters: [String] = [], streams = ""
        for url in ordered { inputs += ["-i", url.path] }
        // Each clip's sound is fitted to its picture, as when copying, so
        // sound that starts early or runs long doesn't push later clips out of sync.
        for (i, info) in infos.enumerated() {
            let length = seconds(spans[i].length)
            filters.append("[\(i):v:0]setpts=PTS-STARTPTS,scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(String(format: "%.3f", fps)),format=yuv420p[v\(i)]")
            if info.hasAudio {
                filters.append("[\(i):a:0]asetpts=PTS-\(seconds(spans[i].lead))/TB,aresample=48000:async=1:first_pts=0,aformat=sample_rates=48000:channel_layouts=stereo,"
                    + "apad=whole_dur=\(length),atrim=end=\(length)[a\(i)]")
            } else {
                filters.append("anullsrc=r=48000:cl=stereo,atrim=0:\(length)[a\(i)]")
            }
            streams += "[v\(i)][a\(i)]"
        }
        filters.append("\(streams)concat=n=\(ordered.count):v=1:a=1[v][a]")
        let out = context.output(for: ordered[0], label: "joined", ext: "mp4")
        var info = infos[0]; info.width = w; info.height = h
        let args = inputs + ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]"]
            + FFmpeg.videoCodec("mp4", options: context.optionsForFormat("mp4"), info: info) + [out.path]
        try await FFmpeg.run(args, duration: spans.map(\.length).reduce(0, +), context: context)
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.6f", value) }

    /// Where each clip's picture starts after ffmpeg sets the file's clock
    /// to its earliest stream, and how long the picture runs.
    private static func pictureSpans(_ infos: [MediaProbe]) -> [(lead: Double, length: Double)] {
        infos.map { info in
            let lead = info.videoStart - info.startTime
            return (lead, info.videoDuration > 0 ? info.videoDuration : info.duration - lead)
        }
    }

    /// Joins matching clips with their pictures copied back to back. Each
    /// segment spans its clip's picture; the clip's sound is moved onto that
    /// span, fitted to its length and encoded once. Copied AAC would bring
    /// every clip's warm-up samples along and leave a short gap at each seam.
    /// Returns false when ffmpeg won't copy the pictures, or the result
    /// doesn't run as long as the clips, so the caller re-encodes instead.
    private static func joinCopying(_ clips: [URL], infos: [MediaProbe], context: OperationContext) async throws -> Bool {
        let lengths = pictureSpans(infos).map(\.length)
        let list = context.scratch("txt")
        let lines = clips.indices.map { i in
            "file '" + clips[i].path.replacingOccurrences(of: "'", with: "'\\''") + "'\ninpoint " + seconds(infos[i].videoStart)
                + "\nduration " + seconds(lengths[i])
        }
        try lines.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        let out = context.output(for: clips[0], label: "joined", ext: "mp4")
        // The concat demuxer hands these allow-lists on to every clip it opens.
        // Without -copyts ffmpeg would also move the picture by the first
        // clip's sound start, which the concat demuxer reports as its own.
        var args = ["-copyts", "-protocol_whitelist", "file,pipe", "-format_whitelist", FFmpeg.inputFormats + ",concat",
                    "-f", "concat", "-safe", "0", "-i", list.path]
        if infos[0].hasAudio {
            args += clips.flatMap { FFmpeg.inputGuards + ["-i", $0.path] }
            // With file times kept, each picture starts at its own start time.
            let fitted = clips.indices.map { i in
                "[\(i + 1):a:0]asetpts=PTS-\(seconds(infos[i].videoStart))/TB,aresample=async=1:first_pts=0,"
                    + "apad=whole_dur=\(seconds(lengths[i])),atrim=end=\(seconds(lengths[i]))[a\(i)]"
            }
            let sound = fitted.joined(separator: ";") + ";" + lengths.indices.map { "[a\($0)]" }.joined() + "concat=n=\(clips.count):v=0:a=1[a]"
            args += ["-filter_complex", sound, "-map", "0:v:0", "-map", "[a]", "-c:v", "copy", "-c:a", "aac_at", "-b:a", "192k"]
        } else {
            args += ["-map", "0:v:0", "-c:v", "copy"]
        }
        args += StreamCopy.videoTag(infos[0].videoCodec, into: "mp4") + ["-movflags", "+faststart", out.path]
        do {
            let expected = lengths.reduce(0, +)
            try await FFmpeg.run(args, duration: expected, context: context, trustedInputs: true)
            // A mismatch nothing above caught would show as a picture of the wrong length.
            let joined = try await FFmpeg.probe(out)
            let slack = 0.05 + Double(clips.count) / max(1, infos[0].frameRate)
            guard abs(joined.videoDuration - expected) <= slack else { throw LimeError("The copied pictures came out \(joined.videoDuration) s long.") }
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: out)
            context.discard(out)
            return false
        }
    }

    static func snapshots(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let times = options.frameGrabTimes.sorted()
        guard !times.isEmpty else { throw LimeError("Pick at least one moment inside the clip.") }
        let info = try await FFmpeg.probe(source)
        if times.count == 1 {
            let out = context.output(for: source, label: "snapshot", ext: "png")
            try await FFmpeg.run(["-ss", FFmpeg.timestamp(times[0]), "-i", source.path, "-frames:v", "1", "-c:v", "png", out.path], duration: 0, context: nil)
            return
        }
        let folder = try context.outputFolder(for: source, label: "snapshots")
        for (index, t) in times.enumerated() {
            try Task.checkCancellation()
            guard t <= info.duration else { throw LimeError("There's no picture at that moment. Try a bit earlier.") }
            let name = String(format: "Snapshot %03d at %.3fs.png", index + 1, t)
            try await FFmpeg.run(["-ss", FFmpeg.timestamp(t), "-i", source.path, "-frames:v", "1", "-c:v", "png", folder.appendingPathComponent(name).path], duration: 0, context: nil)
            context.progress(Double(index + 1) / Double(times.count))
        }
    }

    static func split(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        let points = options.sliceTimes.filter { $0 > 0.05 && $0 < info.duration - 0.05 }.sorted()
        guard !points.isEmpty else { throw LimeError("Put cut marks inside the clip, not within 0.05 s of the start or end.") }
        for (a, b) in zip(points, points.dropFirst()) where b - a < 0.05 { throw LimeError("Cut marks need at least 0.05 s between them.") }
        let bounds = [0] + points + [info.duration]
        let clips = (0..<(bounds.count - 1)).map { (index: $0, start: bounds[$0], end: bounds[$0 + 1]) }.filter { !options.droppedSlices.contains($0.index) }
        guard !clips.isEmpty else { throw LimeError("At least one piece has to stay.") }
        let fmt = format(source)
        let codec = codecArguments(for: source, info: info, context: context)
        if options.clipExport == .merged {
            let out = context.output(for: source, label: "trimmed", ext: fmt)
            var filters: [String] = [], streams = ""
            for (i, clip) in clips.enumerated() {
                filters.append("[0:v:0]trim=\(clip.start):\(clip.end),setpts=PTS-STARTPTS[v\(i)]")
                if info.hasAudio { filters.append("[0:a:0]atrim=\(clip.start):\(clip.end),asetpts=PTS-STARTPTS[a\(i)]"); streams += "[v\(i)][a\(i)]" } else { streams += "[v\(i)]" }
            }
            filters.append("\(streams)concat=n=\(clips.count):v=1:a=\(info.hasAudio ? 1 : 0)[v]" + (info.hasAudio ? "[a]" : ""))
            let maps = ["-map", "[v]"] + (info.hasAudio ? ["-map", "[a]"] : [])
            try await FFmpeg.run(["-i", source.path, "-filter_complex", filters.joined(separator: ";")] + maps + codec + [out.path],
                                 duration: clips.reduce(0) { $0 + $1.end - $1.start }, context: context)
            return
        }
        let folder = try context.outputFolder(for: source, label: "clips")
        let stem = FormatCatalog.stem(of: source)
        for (n, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let name = "\(stem) \(clip.index + 1).\(fmt)"
            try await FFmpeg.run(["-ss", FFmpeg.timestamp(clip.start), "-t", FFmpeg.timestamp(clip.end - clip.start), "-i", source.path,
                                  "-map", "0:v:0", "-map", "0:a?"] + codec + [folder.appendingPathComponent(name).path], duration: 0, context: nil)
            context.progress(Double(n + 1) / Double(clips.count))
        }
    }

    static func visualize(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard info.hasAudio, info.duration > 0 else { throw LimeError("No playable sound here.") }
        let size: (Int, Int) = options.waveCanvas == .landscape ? (1920, 1080) : options.waveCanvas == .portrait ? (1080, 1920) : (1080, 1080)
        let out = context.output(for: source, label: "visualizer", ext: "mp4")
        var args: [String]
        if options.waveLook == .poster {
            guard let image = options.posterURL else { throw LimeError("Pick a picture for the poster first.") }
            args = ["-loop", "1", "-framerate", "2", "-i", image.path, "-i", source.path, "-filter_complex",
                    "[0:v]scale=\(size.0):\(size.1):force_original_aspect_ratio=decrease,pad=\(size.0):\(size.1):(ow-iw)/2:(oh-ih)/2:black,format=yuv420p[v]",
                    "-map", "[v]", "-map", "1:a:0", "-shortest", "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "1500k", "-r", "2"]
        } else {
            let waveHeight = size.1 / 3
            args = ["-i", source.path, "-filter_complex",
                    "[0:a:0]aformat=channel_layouts=mono,showwaves=s=\(size.0)x\(waveHeight):mode=cline:rate=30:colors=0x5CB80D:scale=sqrt,format=yuva420p[w];color=c=black:s=\(size.0)x\(size.1):r=30[bg];[bg][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]",
                    "-map", "[v]", "-map", "0:a:0", "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "4000k"]
        }
        args += ["-c:a", "aac_at", "-b:a", "192k", "-movflags", "+faststart", out.path]
        try await FFmpeg.run(args, duration: info.duration, context: context)
    }

    static func channels(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard info.hasAudio else { throw LimeError("Pick mono or stereo for a file that has sound.") }
        let left = min(2, max(0, options.leftGain)), right = min(2, max(0, options.rightGain))
        func g(_ v: Double) -> String { String(format: "%.4f", v) }
        let filter: String
        if options.outputChannels == 1 {
            filter = info.remixChannels >= 2 ? "pan=mono|c0=\(g(left * 0.5))*c0+\(g(right * 0.5))*c1" : "pan=mono|c0=\(g(left))*c0"
        } else {
            filter = info.remixChannels >= 2 ? "pan=stereo|c0=\(g(left))*c0|c1=\(g(right))*c1" : "pan=stereo|c0=\(g(left))*c0|c1=\(g(right))*c0"
        }
        let out = context.output(for: source, label: options.outputChannels == 1 ? "Mono" : "Stereo", ext: format(source))
        let args = ["-i", source.path, "-map", "0:a:0", "-vn", "-af", filter] + FFmpeg.metadataArguments(preserve: true)
            + codecArguments(for: source, info: info, context: context) + [out.path]
        try await FFmpeg.run(args, duration: info.duration, context: context)
    }

    static func maskVideo(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        guard !options.redactions.isEmpty else { throw LimeError("Draw a box over what should be hidden.") }
        let info = try await FFmpeg.probe(source)
        var chain: [String] = []
        var last = "0:v:0"
        for (i, r) in options.redactions.enumerated() {
            let x = Int(r.rect.minX * Double(info.width)), y = Int(r.rect.minY * Double(info.height))
            let w = max(2, Int(r.rect.width * Double(info.width))), h = max(2, Int(r.rect.height * Double(info.height)))
            let end = r.end.isFinite ? min(r.end, info.duration) : info.duration + 1
            let enable = "between(t,\(FFmpeg.timestamp(r.start)),\(FFmpeg.timestamp(end)))"
            if options.maskFill == .solid {
                let c = options.maskColor
                let hex = String(format: "0x%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
                chain.append("[\(last)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=\(hex):t=fill:enable='\(enable)'[r\(i)]")
            } else {
                let radius = max(1, min(24, min(w, h) / 5))
                chain.append("[\(last)]split[b\(i)][c\(i)];[c\(i)]crop=\(w):\(h):\(x):\(y),gblur=sigma=\(radius)[k\(i)];[b\(i)][k\(i)]overlay=\(x):\(y):enable='\(enable)'[r\(i)]")
            }
            last = "r\(i)"
        }
        let out = context.output(for: source, label: "redacted", ext: format(source))
        let args = ["-i", source.path, "-filter_complex", chain.joined(separator: ";"), "-map", "[\(last)]", "-map", "0:a?", "-map_metadata", "-1"]
            + codecArguments(for: source, info: info, context: context) + [out.path]
        try await FFmpeg.run(args, duration: info.duration, context: context)
    }

    static func bleep(_ source: URL, options: ToolChoices, context: OperationContext) async throws {
        let info = try await FFmpeg.probe(source)
        guard info.hasAudio else { throw LimeError("This file has no sound.") }
        let ranges = options.censorSpans.filter { $0.upperBound > $0.lowerBound && $0.lowerBound < info.duration }
        guard !ranges.isEmpty else { throw LimeError("Mark at least one part to bleep.") }
        let condition = ranges.map { "between(t,\(FFmpeg.timestamp($0.lowerBound)),\(FFmpeg.timestamp(min($0.upperBound, info.duration))))" }.joined(separator: "+")
        let rate = info.sampleRate > 0 ? info.sampleRate : 48000
        let filter = "[0:a:0]volume=0:enable='\(condition)'[m];sine=frequency=1000:sample_rate=\(rate):duration=\(FFmpeg.timestamp(info.duration)),volume=0.35,volume=0:enable='not(\(condition))'[b];[m][b]amix=inputs=2:duration=first:normalize=0[a]"
        let out = context.output(for: source, label: "bleeped", ext: format(source))
        var args = ["-i", source.path, "-filter_complex", filter, "-map", "[a]"] + FFmpeg.metadataArguments(preserve: true)
        args += codecArguments(for: source, info: info, context: context)
        try await FFmpeg.run(args + [out.path], duration: info.duration, context: context)
    }
}
