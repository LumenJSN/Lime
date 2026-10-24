import AppKit

/// Wheel geometry, catalog tables, wheel controller and drag monitor checks.
@main
enum InteractionChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0, failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        // MARK: Catalog tables
        let routes = FormatCatalog.allInputFormats.reduce(0) { $0 + FormatCatalog.targets(for: $1).count }
        expect(routes == 269, "route count \(routes) == 269")
        expect(LimeTool.allCases.filter { !$0.isExtra }.count == 27, "27 core tools")
        expect(LimeTool.allCases.filter(\.isExtra) == [.copyText, .removeBackground], "two extra tools")
        expect(WheelCatalog.items(for: [URL(fileURLWithPath: "/a.jpg")], mode: .tools).count == 7, "extras hidden unless enabled")
        expect(WheelCatalog.items(for: [URL(fileURLWithPath: "/a.pdf")], mode: .tools, extras: true).last?.title == "COPY TEXT", "extras follow the core tools")
        expect(MarkdownRenderer.inline("*기울임*과").contains("<em>기울임</em>"), "intraword * emphasis")
        do {
            var doc = SemanticDocument()
            let t = { (s: String) in [SemanticDocument.Inline.run(.init(text: s))] }
            doc.blocks = [.listItem(ordered: false, level: 0, t("a")), .listItem(ordered: false, level: 0, t("b")),
                          .listItem(ordered: true, level: 0, t("one")), .listItem(ordered: true, level: 0, t("two"))]
            let md = DocumentSerializer.markdown(doc)
            expect(md.contains("1. one") && md.contains("2. two") && md.contains("- b\n\n1. one"), "markdown restarts numbering after bullets")
        }
        expect(!MarkdownRenderer.inline("2 * 3 * 4").contains("<em>"), "spaced asterisks stay literal")
        expect(!MarkdownRenderer.inline("snake_case_name").contains("<em>"), "intraword _ stays literal")

        // MARK: Untrusted document content
        expect(!MarkdownRenderer.inline("[x](javascript:alert(1))").contains("href"), "javascript links dropped")
        expect(!SafeLink.isAllowedLink("java\tscript:alert(1)") && !SafeLink.isAllowedLink(" JavaScript:x") && !SafeLink.isAllowedLink("file:///etc/hosts"), "split and odd schemes refused")
        expect(MarkdownRenderer.inline("[x](https://example.com)").contains("href=\"https://example.com\""), "web links kept")
        expect(!MarkdownRenderer.inline("![a](https://example.com/t.png)").contains("<img"), "remote images dropped")
        expect(!MarkdownRenderer.inline("![a](../secret.png)").contains("<img"), "parent-folder images dropped")
        expect(MarkdownRenderer.inline("![a](img/p.png)").contains("<img src=\"img/p.png\""), "relative images kept")
        let pkg = URL(fileURLWithPath: "/tmp/pkg"), word = pkg.appendingPathComponent("word")
        expect(PackagePath.contained("../../etc/passwd", from: word, in: pkg) == nil, "package escape refused")
        expect(PackagePath.contained("file:///etc/passwd", from: pkg, in: pkg) == nil, "package URL refused")
        expect(PackagePath.contained("../pkg2/x", from: pkg, in: pkg) == nil, "sibling folder refused")
        expect(PackagePath.contained("media/a.png", from: word, in: pkg)?.path.hasSuffix("/pkg/word/media/a.png") == true, "package file allowed")
        expect(PackagePath.contained("/word/media/a.png", from: word, in: pkg)?.path.hasSuffix("/pkg/word/media/a.png") == true, "package-absolute part allowed")
expect(!MarkdownRenderer.inline("![a](%2e%2e/secret.png)").contains("<img") && !MarkdownRenderer.inline("![a](%252e%252e/s.png)").contains("<img"), "encoded parent segments dropped")
        let book = ChapterSanitizer.clean(#"<p onclick="x()" style="background:\75rl(http://e.com/s)">a</p><script>alert(1)</script><img src="http://e.com/t.png"/><img src='../../../etc/x.png'/><img/src="http://e.com/u.png"/><svg><use href="http://e.com/v"/><image href="http://e.com/w.png"/></svg><a href="javascript:alert(1)">l</a><a href="https://ok.example">w</a><blink>kept text</blink>"#, folder: pkg, root: pkg)
        expect(!book.contains("script") && !book.contains("onclick") && !book.contains("e.com") && !book.contains("etc/x") && !book.contains("style")
               && !book.contains("javascript") && book.contains("https://ok.example") && book.contains("kept text") && !book.contains("blink"), "epub sanitised: \(book)")
        let loose = ChapterSanitizer.clean("<p>a&nbsp;b<br>c<img src=http://e.com/x>", folder: pkg, root: pkg)
        expect(!loose.contains("e.com") && loose.contains("a"), "html-style chapter sanitised: \(loose)")
        let kept = ChapterSanitizer.clean(##"<h1 class="t">Title</h1><p><img src="images/a%20b.png" alt="cover"/> <a href="#n1">1</a></p>"##, folder: pkg, root: pkg)
        expect(kept.contains("<h1") && kept.contains("Title") && kept.contains("/pkg/images/a%20b.png") && kept.contains("alt=\"cover\"") && kept.contains("href=\"#n1\""), "book content kept: \(kept)")
        let guardedArgs = FFmpeg.guarded(["-i", "a.mp4", "-i", "b.mp4", "out.mp4"])
        expect(guardedArgs.filter { $0 == "-protocol_whitelist" }.count == 2 && guardedArgs[guardedArgs.firstIndex(of: "-i")! - 1] == FFmpeg.inputFormats, "ffmpeg inputs guarded")
        expect(DropAction.allCases.count == 6, "six actions")
        expect(FormatCatalog.targets(for: "wav") == ["mp3", "m4a", "flac", "ogg", "opus", "aiff", "wma"], "audio targets order")
        expect(FormatCatalog.targets(for: "mp4") == ["mov", "mkv", "avi", "wmv", "gif", "mp3"], "video targets (no WEBM output)")
        expect(FormatCatalog.targets(for: "webm") == ["mp4", "mov", "mkv", "avi", "wmv", "gif", "mp3"], "webm input")
        expect(FormatCatalog.targets(for: "rtf").contains("docx") && !FormatCatalog.targets(for: "docx").contains("rtf"), "rtf input only")
        expect(FormatCatalog.targets(for: "zip") == ["tar", "gz"], "archive targets")
        expect(FormatCatalog.format(of: URL(fileURLWithPath: "/a/b.tar.gz")) == "gz" && FormatCatalog.stem(of: URL(fileURLWithPath: "/a/b.tar.gz")) == "b", "tar.gz stem")
        expect(LimeTool.tools(for: "jpg", count: 1) == [.adjustPhoto, .cropPhoto, .markUpPhoto, .maskPhoto, .addBackdrop, .stripTags, .compress], "image tools")
        expect(LimeTool.tools(for: ["png", "svg"]) == [.makeMosaic, .imagesToPDF], "image + svg")
        expect(LimeTool.tools(for: ["pdf", "png"]) == [.scanQR], "pdf + image reads QR only")
        expect(LimeTool.tools(for: ["mov", "wav"]).isEmpty, "audio + video has no tools")
        expect(LimeTool.tools(for: ["wav", "mp3"]) == [.levelAudio, .stripTags, .compress], "multi audio")
        expect(LimeTool.tools(for: ["svg"]) == [.scanQR], "svg reads QR")
        expect(LimeTool.tools(for: ["zip", "zip"]) == [.unpackArchive], "multi archive")
        expect(LimeTool.tools(for: "png", count: 3) == [.cropPhoto, .makeMosaic, .imagesToPDF, .stripTags, .compress], "multi image tools")
        expect(LimeTool.tools(for: "mov", count: 2) == [.stitchVideos, .silenceVideo, .stripTags, .compress], "multi video tools")
        expect(LimeTool.tools(for: "pdf", count: 2) == [.combinePDFs, .splitPages, .scanQR, .stripTags, .compress], "multi pdf")
        expect(LimeTool.tools(for: "pdf", count: 1) == [.arrangePages, .splitPages, .scanQR, .stripTags, .compress], "pdf tools")
        expect(LimeTool.tools(for: "gif", count: 1) == [.scanQR, .stripTags], "gif tools")
        let mixed = WheelCatalog.items(for: [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.png")], mode: .convert).map(\.title)
        expect(mixed == ["WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF"], "jpg+png shared targets \(mixed)")
        expect(WheelCatalog.items(for: [URL(fileURLWithPath: "/a.jpg"), URL(fileURLWithPath: "/b.mp3")], mode: .convert).isEmpty, "no shared conversions")
        expect(WheelCatalog.items(for: [URL(fileURLWithPath: "/a.zip")], mode: .convert).map(\.title) == ["TAR", "GZIP"], "GZIP label")
        expect(OutputPublisher.uniqueURL(directory: FileManager.default.temporaryDirectory, stem: "Lime-\(UUID().uuidString)", ext: "tar.gz").lastPathComponent.hasSuffix(".tar.gz"), "compound extension")

        // MARK: Geometry
        let g = WheelGeometry()
        expect(abs(g.labelRadius - 93) < 0.01, "label radius")
        for count in 1...10 {
            for index in 0..<count {
                let a = g.bearing(index, of: count)
                for radius: CGFloat in [50, 58, 90, 124, 145] {
                    let p = g.point(radius: radius, bearing: a)
                    expect(g.hit(p, count: count) == index, "\(count)-item sector \(index) at \(radius)")
                }
                let path = g.petalPath(index, of: count)
                let centroid = g.point(radius: (g.inner + g.outer) / 2, bearing: a)
                expect(path.contains(centroid), "petal \(index)/\(count) contains its centre")
            }
            for p in [CGPoint.zero, CGPoint(x: 30, y: 0), CGPoint(x: 0, y: 160), CGPoint(x: -155, y: 0)] {
                expect(g.hit(p, count: count) == nil, "\(count)-item dead zone \(p)")
            }
        }
        expect(g.hit(CGPoint(x: 0, y: -100), count: 4) == 0, "north is first (y-down)")
        expect(g.hit(CGPoint(x: 100, y: 0), count: 4) == 1, "clockwise second is east")
        expect(g.hit(CGPoint(x: 0, y: -100), count: 3) == 0, "three items also start north")
        expect(g.hit(CGPoint(x: 69, y: -72), count: 4) == 0 && g.hit(CGPoint(x: 72, y: -69), count: 4) == 1, "a gutter picks the nearer petal")
        expect(g.hit(CGPoint(x: 0, y: -44), count: 4) == nil, "the hub cancels")
        expect(g.hit(CGPoint(x: 0, y: -150), count: 4) == 0, "a little past the petals still selects")
        expect(g.hit(CGPoint(x: 0, y: 100), count: 1) == 0, "single item ring selectable")

        // MARK: Controller hover/commit
        let settings = AppSettings(defaults: UserDefaults(suiteName: "LimeChecks-\(UUID().uuidString)")!)
        settings.feedback = false
        let controller = WheelController(settings: settings)
        var chosen: [(WheelOperation, [URL])] = []
        controller.onChoose = { op, files, _ in chosen.append((op, files)) }
        let wav = URL(fileURLWithPath: "/tmp/sample.wav")
        controller.show(files: [wav], mode: .convert, at: NSPoint(x: 500, y: 500))
        expect(controller.model.items.count == 7, "wav wheel has 7 targets")
        controller.hover(CGPoint(x: 0, y: -100))
        expect(controller.model.selected == 0, "hover north selects MP3")
        controller.hover(CGPoint(x: 5, y: 5))
        expect(controller.model.selected == nil, "centre clears selection")
        expect(controller.commit(files: nil, at: .zero) == false, "centre drop cancels")
        controller.hover(CGPoint(x: 0, y: -100))
        expect(controller.commit(files: [wav], at: .zero), "drop on petal commits")
        if case .convert(let f)? = chosen.last?.0 { expect(f == "mp3", "committed MP3") } else { expect(false, "convert committed") }
        // Finder delivers the drop after the mouse-up that ends the drag.
        controller.show(files: [wav], mode: .convert, at: .zero)
        controller.hover(CGPoint(x: 0, y: -100))
        controller.dragEnded(after: 0.05)
        expect(controller.model.selected == 0, "drag end keeps the highlighted petal for the late drop")
        expect(controller.commit(files: [wav], at: .zero), "drop after mouse-up still commits")
        controller.show(files: [wav], mode: .convert, at: .zero)
        controller.dragEnded(after: 0.05)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(!controller.model.presented, "drag end without a drop closes the wheel")
        controller.show(files: [wav], mode: .convert, at: .zero)
        controller.dragEnded(after: 0.05)
        controller.dismiss()
        controller.show(files: [wav], mode: .convert, at: .zero)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(controller.model.presented, "a stale drag-end timer does not close a newer wheel")
        // With no petal under the pointer no drop can land, so the wheel goes at once.
        controller.dismiss()
        controller.show(files: [wav], mode: .convert, at: .zero)
        controller.dragEnded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(!controller.model.presented, "drag end over nothing closes without the drop grace")
        controller.show(files: [wav], mode: .convert, at: .zero)
        controller.hover(CGPoint(x: 0, y: -100))
        controller.dragEnded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(controller.model.presented && controller.model.selected == 0, "drag end over a petal still waits for the drop")
        expect(controller.commit(files: [wav], at: .zero), "the waited-for drop commits")
        let warm = WheelController(settings: settings)
        warm.prewarm()
        expect(!warm.isVisible, "prewarming leaves the wheel hidden")
        warm.show(files: [wav], mode: .convert, at: .zero)
        expect(warm.model.items.count == 7 && warm.model.selected == nil, "a prewarmed wheel shows normally")
        warm.dismiss()
        expect(OperationProgressModel.elapsedLabel(0.42) == "0.4s" && OperationProgressModel.elapsedLabel(0.01) == "0.1s", "sub-second times keep a decimal")
        expect(OperationProgressModel.elapsedLabel(12.6) == "13s" && OperationProgressModel.elapsedLabel(75) == "1m 15s", "longer times round to seconds")
        controller.show(files: [wav], mode: .convert, at: .zero)
        controller.setMode(.tools)
        expect(controller.model.items.map(\.title).first == "TRIM", "mode switch to tools")
        controller.setMode(.actions)
        expect(controller.model.items.count == 6, "actions wheel")
        controller.step(1)
        expect(controller.model.selected == 0, "keyboard step selects first")
        controller.step(-1)
        expect(controller.model.selected == 5, "keyboard step wraps")
        controller.dismiss()

        // MARK: Drag monitor state machine
        var pressed = false, flags: NSEvent.ModifierFlags = [], location = NSPoint(x: 100, y: 100), count = 1
        var dragFiles = [wav]
        let inputs = DragWatcher.Inputs(buttonPressed: { pressed }, modifiers: { flags }, location: { location }, changeCount: { count }, files: { dragFiles })
        let monitor = DragWatcher(settings: settings, inputs: inputs)
        var taps: [WheelMode] = [], ended = 0
        monitor.onTap = { _, mode, _ in taps.append(mode) }
        monitor.onDragEnded = { ended += 1 }
        flags = .shift; monitor.poll(); flags = []; monitor.poll()
        expect(taps.isEmpty, "no wheel without a drag")
        pressed = true; monitor.poll()
        location = NSPoint(x: 140, y: 100); monitor.poll()
        expect(!monitor.dragging, "moving without new drag pasteboard is not a file drag")
        flags = .shift; monitor.poll(); flags = []; monitor.poll()
        expect(taps.isEmpty, "stale pasteboard from an earlier drag is ignored")
        pressed = false; monitor.poll()
        pressed = true; monitor.poll()
        count += 1; location = NSPoint(x: 200, y: 160); monitor.poll()
        expect(monitor.dragging && monitor.files == [wav], "new drag pasteboard starts a file drag")
        flags = .shift; monitor.poll()
        expect(taps == [.convert], "shift tap opens conversions")
        monitor.poll()
        expect(taps == [.convert], "held key does not retrigger")
        flags = []; monitor.poll(); flags = .command; monitor.poll()
        expect(taps == [.convert, .tools], "command switches to tools")
        flags = [.command, .shift]; monitor.poll()
        expect(taps.count == 2, "unassigned combination ignored")
        flags = []; monitor.poll(); flags = .control; monitor.poll()
        expect(taps.last == .actions, "control opens actions")
        pressed = false; flags = []; monitor.poll()
        expect(ended == 1 && !monitor.dragging, "mouse up ends the drag")
        settings.monitoring = false
        pressed = true; count += 1; location = NSPoint(x: 400, y: 400); monitor.poll(); flags = .shift; monitor.poll()
        expect(taps.count == 3, "paused monitoring ignores drags")
        settings.conversions = KeyChord(flags: [.control, .option])
        expect(settings.mode(for: [.control, .option]) == .convert, "custom combination resolves")
        dragFiles = []

        // MARK: Stream copy
        do {
            let mp4Family = "mov,mp4,m4a,3gp,3g2,mj2", matroska = "matroska,webm"
            func probe(_ video: String, _ pix: String = "yuv420p", audio: String = "aac", in container: String = "mov,mp4,m4a,3gp,3g2,mj2") -> MediaProbe {
                var p = MediaProbe(); p.hasVideo = true; p.hasAudio = !audio.isEmpty; p.container = container
                p.videoCodec = video; p.pixelFormat = pix; p.audioCodec = audio; p.width = 1920; p.height = 1080
                return p
            }
            let plain = ConvertPrefs()
            var capped = ConvertPrefs(); capped.maxVideoHeight = 720
            var smaller = ConvertPrefs(); smaller.qualityPreset = .smaller
            expect(StreamCopy.plan(probe("h264"), into: "mp4", options: plain) == .init(video: true, audio: true), "h264+aac mov→mp4 is copied whole")
            expect(StreamCopy.plan(probe("h264", in: matroska), into: "mp4", options: plain) == .init(video: true, audio: false),
                   "aac from mkv is re-encoded for mp4, which marks its start-up samples differently")
            expect(StreamCopy.plan(probe("h264", in: mp4Family), into: "mkv", options: plain) == .init(video: true, audio: false), "aac from mp4 is re-encoded for mkv")
            expect(StreamCopy.plan(probe("h264", audio: "flac", in: matroska), into: "mkv", options: plain).audio, "mkv keeps flac")
            expect(StreamCopy.plan(probe("hevc", "yuv420p10le"), into: "mov", options: plain) == .init(video: true, audio: true), "10-bit hevc copies into mov")
            expect(StreamCopy.plan(probe("h264", audio: "opus"), into: "mp4", options: plain) == .init(video: true, audio: false), "opus is re-encoded for mp4")
            expect(StreamCopy.plan(probe("h264", audio: "opus", in: matroska), into: "mkv", options: plain) == .init(video: true, audio: true), "mkv keeps opus")
            expect(StreamCopy.plan(probe("h264", "yuv422p10le"), into: "mp4", options: plain).video == false, "10-bit 4:2:2 h264 is re-encoded")
            expect(StreamCopy.plan(probe("vp9", audio: "opus"), into: "mp4", options: plain).video == false, "vp9 is re-encoded for mp4")
            expect(StreamCopy.plan(probe("h264"), into: "mp4", options: capped).video == false, "a height cap needs a re-encode")
            expect(StreamCopy.plan(probe("h264"), into: "mp4", options: smaller).video == false, "Smaller File still makes the file smaller")
            var small = probe("h264"); small.height = 480
            expect(StreamCopy.plan(small, into: "mp4", options: capped).video, "a clip under the cap is still copied")
            expect(StreamCopy.plan(probe("h264"), into: "avi", options: plain) == .init(video: false, audio: false), "avi always re-encodes")
            var rated = probe("h264"); rated.encodeKbps = 192_000
            expect(StreamCopy.plan(rated, into: "m4a", options: plain).audio, "aac goes into m4a as is")
            var unrated = probe("", audio: "opus", in: "ogg"); unrated.hasVideo = false
            expect(!StreamCopy.plan(unrated, into: "opus", options: plain).audio, "audio of unknown bitrate is re-encoded to the chosen one")
            var modest = unrated; modest.encodeKbps = 96_000
            expect(StreamCopy.plan(modest, into: "opus", options: plain).audio, "opus under the chosen bitrate is copied")
            expect(!StreamCopy.plan(probe("h264", in: "avi"), into: "mp4", options: plain).video, "avi pictures are re-encoded, since avi keeps no display times")
            var loud = probe("h264"); loud.encodeKbps = 320_000
            expect(!StreamCopy.plan(loud, into: "m4a", options: plain).audio, "audio above the chosen bitrate is re-encoded down to it")
            expect(StreamCopy.plan(probe("h264", audio: "mp3"), into: "mp3", options: plain).audio == false, "mp3 from mp4 is re-encoded so its start lines up")
            expect(!StreamCopy.plan(probe("h264", audio: "aac"), into: "mp3", options: plain).audio, "aac becomes mp3")
            expect(!StreamCopy.plan(probe("h264", audio: "pcm_s16le"), into: "wav", options: plain).audio, "wav keeps its bit-depth choice")
            var clip = probe("h264"); clip.frameRate = 30; clip.sampleRate = 48000; clip.remixChannels = 2
            clip.videoTimeBase = "1/15360"; clip.streamKinds = ["video", "audio"]; clip.videoExtradata = "aa"; clip.videoDuration = 3; clip.videoFrames = 90
            var other = clip; other.width = 1280; other.height = 720
            var silent = clip; silent.hasAudio = false; silent.audioCodec = ""
            expect(StreamCopy.canJoin([clip, clip]), "matching clips join without re-encoding")
            expect(!StreamCopy.canJoin([clip, other]), "different sizes need a re-encode")
            expect(!StreamCopy.canJoin([clip, silent]), "a silent clip among sound clips needs a re-encode")
            expect(!StreamCopy.canJoin([probe("vp9", audio: "opus"), probe("vp9", audio: "opus")]), "vp9 can't be joined into mp4 as is")
            var mkvClip = clip; mkvClip.container = matroska
            expect(StreamCopy.canJoin([mkvClip, mkvClip]), "mkv clips join with copied picture; their sound is re-encoded anyway")
            expect(!StreamCopy.canJoin([clip, mkvClip]), "mp4 and mkv clips keep time differently, so they are re-encoded")
            var ticks = clip; ticks.videoTimeBase = "1/600"
            expect(!StreamCopy.canJoin([clip, ticks]), "clips that count time in different units are re-encoded")
            var flipped = clip; flipped.streamKinds = ["audio", "video"]
            expect(!StreamCopy.canJoin([clip, flipped]), "clips with their tracks in another order are re-encoded")
            var otherEncoder = clip; otherEncoder.videoExtradata = "bb"
            expect(!StreamCopy.canJoin([clip, otherEncoder]), "clips from different encoder settings are re-encoded")
            var trimmed = clip; trimmed.videoFrames = 140
            expect(!StreamCopy.canJoin([trimmed, trimmed]), "clips hiding trimmed-off frames are re-encoded")
            var unknownCount = clip; unknownCount.videoFrames = 0
            expect(StreamCopy.canJoin([unknownCount, unknownCount]), "clips without a frame count still join")
            expect(FFmpeg.clockSeconds("00:01:03.021000000").map { abs($0 - 63.021) < 1e-9 } == true && FFmpeg.clockSeconds("N/A") == nil, "matroska durations read")
            expect(StreamCopy.videoTag("hevc", into: "mp4") == ["-tag:v", "hvc1"] && StreamCopy.videoTag("h264", into: "mkv").isEmpty, "hevc tagged for QuickTime")
        }

        // MARK: Loudness
        do {
            let report = """
            [Parsed_ebur128_0 @ 0x1] Summary:

              Integrated loudness:
                I:         -10.8 LUFS
                Threshold: -20.7 LUFS

              Loudness range:
                LRA:         2.6 LU
                Threshold: -30.7 LUFS

              True peak:
                Peak:      -11.6 dBFS
            """
            let m = Loudness.parse(report)
            expect(m == Loudness.Measure(integrated: -10.8, range: 2.6, peak: -11.6), "ebur128 summary parsed")
            expect(Loudness.parse("no summary here") == nil, "missing summary is nil")
            let loudnormLog = """
            [Parsed_loudnorm_0 @ 0x1]
            {
            	"input_i" : "-27.61",
            	"input_tp" : "-4.47"
            }
            [out#0/null @ 0x2] video:0KiB audio:0KiB subtitle:0KiB
            """
            expect(Loudness.loudnormReport(loudnormLog) == ["input_i": "-27.61", "input_tp": "-4.47"], "loudnorm's report read with log lines after it")
            expect(Loudness.loudnormReport("no json") == nil, "missing loudnorm report is nil")
            expect(Loudness.linearGain(m!, target: -16, range: 11, peak: -1.5) == -5.2, "quiet-enough audio gets a plain gain")
            var loud = m!; loud.integrated = -30; loud.peak = -3
            expect(Loudness.linearGain(loud, target: -16, range: 11, peak: -1.5) == nil, "a gain that would clip needs the limiter")
            var wide = m!; wide.range = 15
            expect(Loudness.linearGain(wide, target: -16, range: 11, peak: -1.5) == nil, "wide range needs dynamic levelling")
            var silent = m!; silent.integrated = -70; silent.peak = -.infinity
            expect(Loudness.linearGain(silent, target: -16, range: 11, peak: -1.5) == nil, "silence is left to loudnorm")
        }

        // MARK: Parallel files
        do {
            let studio = Parallelism.Machine(cores: 18, memoryGB: 48, thermal: .nominal, lowPower: false)
            let laptop = Parallelism.Machine(cores: 4, memoryGB: 8, thermal: .nominal, lowPower: false)
            expect(Parallelism.limit(for: [.image, .image], on: studio) == 8, "pictures run one per core, up to 8")
            expect(Parallelism.limit(for: [.audio], on: studio) == 8, "audio leaves ffmpeg room on a big Mac")
            expect(Parallelism.limit(for: [.video], on: studio) == 2, "two videos at a time")
            expect(Parallelism.limit(for: [.image, .video], on: studio) == 2, "a mixed selection takes the tighter limit")
            expect(Parallelism.limit(for: [.document], on: studio) == 1 && Parallelism.limit(for: [nil], on: studio) == 1, "documents stay one at a time")
            expect(Parallelism.limit(for: [.image], on: laptop) == 4 && Parallelism.limit(for: [.audio], on: laptop) == 2, "a 4-core 8 GB Mac runs fewer at once")
            var small = studio; small.memoryGB = 4
            expect(Parallelism.limit(for: [.image], on: small) == 2, "little memory caps pictures")
            var warm = studio; warm.thermal = .serious
            expect(Parallelism.limit(for: [.image], on: warm) == 4, "a hot Mac halves the work")
            var hot = studio; hot.thermal = .critical
            expect(Parallelism.limit(for: [.image], on: hot) == 1, "a very hot Mac runs one file at a time")
            var saving = studio; saving.lowPower = true
            expect(Parallelism.limit(for: [.image], on: saving) == 4, "Low Power Mode halves the work")
            expect(Parallelism.Machine.current.cores >= 1 && Parallelism.limit(for: [.image]) >= 1, "this Mac gets a sensible limit")
        }

        // MARK: Surface style
        do {
            func fresh(_ setup: (UserDefaults) -> Void) -> AppSettings {
                let defaults = UserDefaults(suiteName: "LimeSurface-\(UUID().uuidString)")!
                setup(defaults)
                return AppSettings(defaults: defaults)
            }
            expect(fresh { _ in }.surface == SurfaceStyle.standard, "new installs start on the best glass this Mac has")
            expect(fresh { $0.set(false, forKey: "glass") }.surface == .solid, "an old Solid choice stays Solid")
            expect(fresh { $0.set(true, forKey: "glass") }.surface == SurfaceStyle.standard, "an old Glass choice moves to the default glass")
            expect(fresh { $0.set("frosted", forKey: "surface") }.surface == .frosted, "Frosted can be chosen on any Mac")
            let liquid = fresh { $0.set("liquid", forKey: "surface") }.surface
            expect(liquid == (SurfaceStyle.liquidAvailable ? .liquid : .frosted), "Liquid Glass falls back to Frosted without macOS 26")
            expect(SurfaceStyle.offered.contains(.liquid) == SurfaceStyle.liquidAvailable, "Settings only offers Liquid Glass where it exists")
            expect(!fresh { $0.set("solid", forKey: "surface") }.glass, "Solid is opaque")
        }

        // MARK: Tool windows
        do {
            let photo = FileManager.default.temporaryDirectory.appendingPathComponent("Lime-\(UUID().uuidString).jpg")
            try? Data(count: 4096).write(to: photo)
            let compress = ToolWindowController(tool: .compress, files: [photo], settings: settings) { _, _ in }
            compress.show(near: NSPoint(x: 600, y: 500))
            if let window = compress.window {
                let fits = { abs(window.frame.height - ToolWindowController.contentHeight(model: compress.model, width: window.frame.width)) < 1 }
                expect(fits(), "compress window is exactly as tall as its controls")
                compress.model.options.sizeGoal = compress.model.options.sizeGoal == .preset ? .percentage : .preset
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                expect(fits(), "compress window still fits after a mode change")
                window.close()
            } else { expect(false, "compress window opens") }
            try? FileManager.default.removeItem(at: photo)
        }

        print("PASS: \(checks - failures.count)/\(checks) interaction checks")
        for f in failures { print("FAIL " + f) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
