import AppKit
import PDFKit
import AVFoundation

/// Executes every file tool on generated fixtures and verifies outputs.
@main
enum ToolChecks {
    static let defaults: @Sendable (String) -> ConvertPrefs = { _ in ConvertPrefs() }

    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LimeTools-" + UUID().uuidString, isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["KEEP"] == nil { try? fm.removeItem(at: root) } }
        var passed = 0, failed: [String] = []
        func expect(_ ok: Bool, _ name: String) { if ok { passed += 1; print("ok   \(name)") } else { failed.append(name); print("FAIL \(name)") } }
        func check(_ name: String, _ tool: LimeTool, _ files: [URL], _ configure: (inout ToolChoices) -> Void = { _ in },
                   verify: (([URL]) throws -> Void)? = nil) async {
            var options = ToolChoices()
            configure(&options)
            do {
                let context = try OperationContext(outputDirectory: root, optionsForFormat: defaults)
                let results = try await ToolEngine.run(tool, files: files, options: options, context: context)
                guard !results.isEmpty else { throw LimeError("no output") }
                for url in results {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    var dir: ObjCBool = false
                    _ = fm.fileExists(atPath: url.path, isDirectory: &dir)
                    guard dir.boolValue || size > 0 else { throw LimeError("empty \(url.lastPathComponent)") }
                }
                try verify?(results)
                passed += 1
                print("ok   \(name) → \(results.map(\.lastPathComponent).joined(separator: ", "))")
            } catch {
                failed.append("\(name): \(error.localizedDescription.prefix(300))")
                print("FAIL \(name): \(error.localizedDescription.prefix(300))")
            }
        }
        do {
            let fx = try await makeFixtures(root)
            let (jpg, png, png2, wav, mp3, mp4, mp4b, pdf, zip) = (fx["jpg"]!, fx["png"]!, fx["png2"]!, fx["wav"]!, fx["mp3"]!, fx["mp4"]!, fx["mp4b"]!, fx["pdf"]!, fx["zip"]!)
            func duration(_ url: URL) async -> Double { (try? await FFmpeg.probe(url).duration) ?? 0 }
            await check("compress jpg preset", .compress, [jpg]) { $0.sizeGoal = .preset }
            // Target modes must land at or under the promised size.
            func bytes(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0 }
            func within(_ source: URL, percent: Double) -> ([URL]) throws -> Void {
                { r in
                    let limit = Int(Double(bytes(source)) * (1 - percent / 100))
                    guard bytes(r[0]) <= limit else { throw LimeError("\(bytes(r[0])) bytes, over the \(limit)-byte target") }
                }
            }
            await check("compress jpg target", .compress, [jpg], { $0.sizeGoal = .percentage; $0.shrinkPercent = 30 }, verify: within(jpg, percent: 30))
            let heic = root.appendingPathComponent("photo.heic")
            try await ImageIOKit.write(ImageIOKit.load(jpg), to: heic, format: "heic", quality: 0.95, metadata: [:])
            await check("compress heic by half", .compress, [heic], { $0.sizeGoal = .percentage; $0.shrinkPercent = 50 }, verify: within(heic, percent: 50))
            await check("compress jpg by half", .compress, [jpg], { $0.sizeGoal = .percentage; $0.shrinkPercent = 50 }, verify: within(jpg, percent: 50))
            await check("compress png", .compress, [png]) { $0.sizeGoal = .preset }
            await check("compress wav→flac", .compress, [wav]) { $0.sizeGoal = .preset } verify: { r in guard r[0].pathExtension == "flac" else { throw LimeError("expected flac") } }
            await check("compress mp3", .compress, [mp3]) { $0.sizeGoal = .preset }
            await check("compress mp4", .compress, [mp4]) { $0.sizeGoal = .preset }
            await check("compress mp4 target", .compress, [mp4]) { $0.sizeGoal = .percentage; $0.shrinkPercent = 25 }
            await check("compress pdf", .compress, [fx["photoPDF"]!]) { $0.sizeGoal = .preset }
            await check("compress pdf strong", .compress, [fx["photoPDF"]!]) { $0.sizeGoal = .preset; $0.squashLevel = .hard }
            // Animated WebP keeps its frames when compressed at original dimensions.
            let animated = root.appendingPathComponent("anim.webp")
            try await FFmpeg.run(["-i", mp4.path, "-t", "1", "-vf", "fps=8,scale=320:-2", "-c:v", "libwebp_anim", "-lossless", "1", "-loop", "0", animated.path], duration: 0, context: nil)
            await check("compress animated webp", .compress, [animated]) { $0.sizeGoal = .preset } verify: { r in
                guard AnimatedImage.frameCount(r[0]) == AnimatedImage.frameCount(animated), AnimatedImage.frameCount(r[0]) > 1 else { throw LimeError("animation lost: \(AnimatedImage.frameCount(r[0])) frames") }
            }
            await check("compress animated webp target", .compress, [animated]) { $0.sizeGoal = .percentage; $0.shrinkPercent = 40 } verify: { r in
                guard AnimatedImage.frameCount(r[0]) > 1 else { throw LimeError("animation lost") }
                guard ImageTools.fileSize(r[0]) <= Int(Double(ImageTools.fileSize(animated)) * 0.6) else { throw LimeError("target not reached") }
            }
            do {
                var options = ToolChoices(); options.sizeGoal = .preset; options.resizeCap = .px1280
                let context = try OperationContext(outputDirectory: root, optionsForFormat: defaults)
                _ = try await ToolEngine.run(.compress, files: [animated], options: options, context: context)
                failed.append("animated webp resize: expected an error"); print("FAIL animated webp resize")
            } catch {
                if error.localizedDescription.contains("the animation would be lost") { passed += 1; print("ok   animated webp resize rejected") }
                else { failed.append("animated webp resize: \(error.localizedDescription)"); print("FAIL animated webp resize: \(error.localizedDescription)") }
            }
            await check("metadata image remove", .stripTags, [jpg])
            await check("metadata image edit", .stripTags, [jpg]) { $0.wipeAllTags = false; $0.tagEntries = [TagEntry(id: "tiff.Artist", label: "Author", value: "Tester")] } verify: { r in
                let tiff = ImageIOKit.properties(r[0])[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
                guard (tiff?[kCGImagePropertyTIFFArtist as String] as? String) == "Tester" else { throw LimeError("artist not written") }
            }
            await check("metadata mp3", .stripTags, [mp3]) { $0.wipeAllTags = false; $0.tagEntries = [TagEntry(id: "ffmpeg.artist", label: "Artist", value: "Lime Tester")] }
            await check("metadata pdf", .stripTags, [pdf])
            await check("edit photo", .adjustPhoto, [jpg]) { $0.photoTweaks.exposure = 30; $0.photoTweaks.vignette = 40; $0.photoTweaks.grain = 30; $0.photoTweaks.clarity = 20 }
            await check("annotate", .markUpPhoto, [jpg]) {
                var a = Markup(kind: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 120))
                var t = Markup(kind: .text, start: CGPoint(x: 20, y: 150), end: CGPoint(x: 300, y: 150)); t.text = "Hello"
                var m = Markup(kind: .magnifier, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 160, y: 100)); m.zoom = 2
                let n = Markup(kind: .number, start: CGPoint(x: 50, y: 50), end: CGPoint(x: 50, y: 50))
                a.lineWidth = 8
                $0.annotations = [a, t, m, n]
            }
            await check("add background", .addBackdrop, [jpg]) { $0.backdropSettings.canvasShape = .square }
            await check("crop image", .cropPhoto, [jpg]) { $0.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) } verify: { r in
                let img = try ImageIOKit.load(r[0]); guard img.width == 160, img.height == 100 else { throw LimeError("crop size \(img.width)x\(img.height)") }
            }
            await check("crop multiple", .cropPhoto, [jpg, png]) { $0.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 1) }
            await check("redact image", .maskPhoto, [jpg]) { $0.redactions = [MaskBox(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))]; $0.maskFill = .blur }
            await check("collage", .makeMosaic, [jpg, png, png2]) { $0.collage.style = .featured }
            await check("create pdf", .imagesToPDF, [jpg, png]) { _ in } verify: { r in guard PDFDocument(url: r[0])?.pageCount == 2 else { throw LimeError("pages") } }
            await check("create pdf keeps jpeg data", .imagesToPDF, [jpg]) { _ in } verify: { r in
                let pdf = try Data(contentsOf: r[0])
                guard pdf.range(of: Data("/DCTDecode".utf8)) != nil else { throw LimeError("jpeg was re-encoded") }
            }
            await check("normalize", .levelAudio, [mp3])
            await check("mute", .silenceVideo, [mp4]) { _ in } verify: { r in
                guard try await_hasAudio(r[0]) == false else { throw LimeError("audio left") }
            }
            await check("trim video", .cutVideo, [mp4]) { $0.cutStart = 0.5; $0.cutLength = 1 }
            await check("trim audio silence", .cutAudio, [wav]) { $0.cutStart = 0; $0.cutLength = 0; $0.dropSilentEnds = true }
            await check("crop video", .cropClip, [mp4]) { $0.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
            await check("speed", .retimeVideo, [mp4]) { $0.tempoFactor = 2 }
            await check("speed slow", .retimeVideo, [mp4]) { $0.tempoFactor = 0.5 }
            func joinedLength(_ clips: [URL]) async -> Double {
                guard let context = try? OperationContext(outputDirectory: root, optionsForFormat: defaults),
                      let joined = try? await ToolEngine.run(.stitchVideos, files: clips, options: ToolChoices(), context: context).first else { return 0 }
                return (try? await FFmpeg.probe(joined).videoDuration) ?? 0
            }
            await check("join", .stitchVideos, [mp4, mp4b])
            let plainJoin = await joinedLength([mp4, mp4b])
            expect(abs(plainJoin - 4) < 0.1, "joined picture runs as long as both clips (\(plainJoin) s)")
            // A clip that counts time in other units can't share the first clip's clock.
            let ticks = root.appendingPathComponent("ticks.mp4")
            try await FFmpeg.run(["-i", mp4b.path, "-c", "copy", "-video_track_timescale", "600", ticks.path], duration: 0, context: nil)
            let mixedJoin = await joinedLength([mp4, ticks])
            expect(abs(mixedJoin - 4) < 0.1, "clips in other time units join at the right length (\(mixedJoin) s)")
            // A line break in a name must not reach ffmpeg's list of clips as a new line.
            let oddName = root.appendingPathComponent("line\nfile 'clip.mp4'.mp4")
            try fm.copyItem(at: mp4b, to: oddName)
            let oddJoin = await joinedLength([mp4, oddName])
            expect(abs(oddJoin - 4) < 0.1, "a clip with a line break in its name joins at the right length (\(oddJoin) s)")
            await check("snapshot one", .grabFrames, [mp4]) { $0.frameGrabTimes = [0.5] }
            await check("snapshots", .grabFrames, [mp4]) { $0.frameGrabTimes = [0.2, 1.0, 1.5] }
            await check("split clips", .sliceVideo, [mp4]) { $0.sliceTimes = [0.7, 1.4] }
            await check("split merged", .sliceVideo, [mp4]) { $0.sliceTimes = [0.7, 1.4]; $0.droppedSlices = [1]; $0.clipExport = .merged }
            await check("visualizer", .waveVideo, [mp3]) { $0.waveCanvas = .square }
            await check("visualizer image", .waveVideo, [mp3]) { $0.waveLook = .poster; $0.posterURL = jpg }
            await check("channels mono", .remixChannels, [mp3]) { $0.outputChannels = 1 }
            await check("channels stereo", .remixChannels, [mp3]) { $0.outputChannels = 2; $0.leftGain = 0.5 }
            await check("redact video", .maskVideo, [mp4]) { $0.redactions = [MaskBox(rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), start: 0.5, end: 1.5)] }
            await check("redact video blur", .maskVideo, [mp4]) { $0.maskFill = .blur; $0.redactions = [MaskBox(rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))] }
            await check("bleep", .censorAudio, [mp3]) { $0.censorSpans = [0.5...1.0] }
            await check("split pdf", .splitPages, [pdf])
            await check("merge pdf", .combinePDFs, [pdf, pdf]) { _ in } verify: { r in guard (PDFDocument(url: r[0])?.pageCount ?? 0) >= 2 else { throw LimeError("merge pages") } }
            await check("organize pdf", .arrangePages, [pdf]) { $0.pageSequence = [0, 0]; $0.pageTurns = [1: 90] }
            await check("extract zip", .unpackArchive, [zip])
            // A member that climbs out of the folder must be refused.
            let evil = root.appendingPathComponent("evil.tar")
            try makeTar(at: evil, name: "../escaped.txt")
            do {
                let context = try OperationContext(outputDirectory: root, optionsForFormat: defaults)
                _ = try await ToolEngine.run(.unpackArchive, files: [evil], options: ToolChoices(), context: context)
                failed.append("unsafe archive was extracted")
            } catch {
                if error.localizedDescription.contains("unsafe"), !fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path) { passed += 1; print("ok   unsafe archive rejected") }
                else { failed.append("unsafe archive: \(error.localizedDescription)") }
            }
            // Document packages must not keep symbolic links that point outside.
            let linkDir = root.appendingPathComponent("linkpkg", isDirectory: true)
            try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: linkDir.appendingPathComponent("hosts").path, withDestinationPath: "/etc/hosts")
            let linkZip = root.appendingPathComponent("linkpkg.zip")
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/zip"), ["-yq", linkZip.path, "hosts"], directory: linkDir)
            let unpacked = root.appendingPathComponent("linkpkg-out", isDirectory: true)
            try await ZipPackage.extract(linkZip, to: unpacked)
            if (try? fm.destinationOfSymbolicLink(atPath: unpacked.appendingPathComponent("hosts").path)) == nil { passed += 1; print("ok   package symlink removed") }
            else { failed.append("package symlink kept") }
            // A concat list disguised as a video must not pull in other local files.
            let playlist = fx["mp3"]!.deletingLastPathComponent().appendingPathComponent("clip.mp4")
            try "ffconcat version 1.0\nfile \(fx["mp3"]!.lastPathComponent)\n".write(to: playlist, atomically: true, encoding: .utf8)
            let leaked = (try? await FFmpeg.probe(playlist)).map { $0.hasAudio || $0.hasVideo } ?? false
            if !leaked { passed += 1; print("ok   playlist input refused") } else { failed.append("playlist input read a local file") }
            _ = duration
            // Extra tools: Copy Text (OCR, also on an image-only PDF) and Remove Background.
            let textImage = try renderTextImage(["Lime OCR 2026", "텍스트 인식 테스트"])
            let textPNG = root.appendingPathComponent("text.png"), scanPDF = root.appendingPathComponent("scan.pdf")
            try ImageIOKit.writeImageIO(textImage, to: textPNG, format: "png", quality: 1, metadata: [:])
            try ImageIOKit.writePDF([textImage], to: scanPDF)
            for (name, url) in [("copy text image", textPNG), ("copy text scanned pdf", scanPDF)] {
                let text = (try? TextRecognition.text(in: url)) ?? ""
                if text.contains("Lime") && text.contains("텍스트") && text.components(separatedBy: "\n").count >= 2 { passed += 1; print("ok   \(name)") }
                else { failed.append("\(name): \(text.debugDescription)"); print("FAIL \(name): \(text.debugDescription)") }
            }
            // Files run side by side: capped, each with its own progress share, outputs in file order.
            do {
                final class Box: @unchecked Sendable { let lock = NSLock(); var running = 0, peak = 0, reports: [Double] = [] }
                let box = Box()
                let context = try OperationContext(outputDirectory: root, optionsForFormat: defaults) { v in box.lock.withLock { box.reports.append(v) } }
                let names = (0..<8).map { root.appendingPathComponent("item\($0).txt") }
                try await context.forEach(names, limit: 3) { index, url in
                    box.lock.withLock { box.running += 1; box.peak = max(box.peak, box.running) }
                    try await Task.sleep(nanoseconds: UInt64(8 - index) * 5_000_000)
                    _ = context.output(for: url, ext: "txt")
                    context.progress(1)
                    box.lock.withLock { box.running -= 1 }
                }
                expect(box.peak == 3, "parallel files capped at the limit (peak \(box.peak))")
                expect(abs((box.reports.max() ?? 0) - 1) < 1e-9 && box.reports == box.reports.sorted(), "progress climbs to 1 across files")
                expect(context.stagedOutputs.map(\.stem) == (0..<8).map { "item\($0)" }, "outputs keep file order")
                var thrown = ""
                do {
                    try await context.forEach(names, limit: 4) { index, _ in if index == 2 { throw LimeError("bad") } }
                } catch { thrown = error.localizedDescription }
                expect(thrown.contains("item2.txt") && thrown.contains("bad"), "a failing file is named in the error")
            }
            // Cancelling stops files that haven't started, even while running ones finish.
            do {
                final class Box: @unchecked Sendable { let lock = NSLock(); var started = 0 }
                let box = Box()
                let context = try OperationContext(outputDirectory: root, optionsForFormat: defaults)
                let names = (0..<6).map { root.appendingPathComponent("slow\($0).txt") }
                let job = Task {
                    try await context.forEach(names, limit: 2) { _, _ in
                        box.lock.withLock { box.started += 1 }
                        usleep(150_000)
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
                job.cancel()
                _ = try? await job.value
                expect(box.started == 2, "cancelling starts no more files (\(box.started) started)")
                let slots = WorkSlots(capacity: 2)
                let late = Task { () async throws -> Bool in
                    while !Task.isCancelled { await Task.yield() }
                    return try await slots.run { true }
                }
                late.cancel()
                let ran = (try? await late.value) ?? false
                expect(!ran, "a cancelled job doesn't take a free slot")
            }
            // Every converted file counts towards the progress, and towards the files saved.
            do {
                final class Box: @unchecked Sendable { let lock = NSLock(); var reports: [Double] = [], done: [Int] = [] }
                let box = Box()
                let context = try OperationContext(outputDirectory: root, optionsForFormat: defaults,
                                                   progress: { v in box.lock.withLock { box.reports.append(v) } },
                                                   filesDone: { n in box.lock.withLock { box.done.append(n) } })
                _ = try await ConversionEngine.convert([png, png2], to: "jpg", context: context)
                expect(box.reports.max() == 1 && box.done.max() == 2 && box.done == box.done.sorted(), "converting pictures reports progress and files saved")
            }
            // WebP keeps see-through pixels as they are.
            do {
                let glass = ImageIOKit.makeContext(width: 8, height: 8)!
                glass.setFillColor(CGColor(gray: 1, alpha: 0.5))
                glass.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                let webp = root.appendingPathComponent("glass.webp"), raw = root.appendingPathComponent("glass.rgba")
                try await ImageIOKit.write(glass.makeImage()!, to: webp, format: "webp", quality: 1)
                try await FFmpeg.run(["-i", webp.path, "-f", "rawvideo", "-pix_fmt", "rgba", raw.path], duration: 0, context: nil)
                let pixel = Array(try Data(contentsOf: raw).prefix(4))
                expect(pixel.count == 4 && pixel[0] >= 250 && pixel[1] >= 250 && pixel[2] >= 250 && abs(Int(pixel[3]) - 128) <= 2, "webp keeps half-clear white white (\(pixel))")
            }
            // Jobs share one pool of slots, and a job waiting for one can be cancelled.
            do {
                final class Box: @unchecked Sendable { let lock = NSLock(); var running = 0, peak = 0 }
                let box = Box(), slots = WorkSlots(capacity: 2)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<5 {
                        group.addTask {
                            try await slots.run {
                                box.lock.withLock { box.running += 1; box.peak = max(box.peak, box.running) }
                                try await Task.sleep(nanoseconds: 10_000_000)
                                box.lock.withLock { box.running -= 1 }
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                expect(box.peak == 2, "jobs share the slot pool (peak \(box.peak))")
                let single = WorkSlots(capacity: 1)
                let blocker = Task { try await single.run { try await Task.sleep(nanoseconds: 2_000_000_000) } }
                try await Task.sleep(nanoseconds: 30_000_000)
                let waiting = Task { try await single.run { true } }
                try await Task.sleep(nanoseconds: 30_000_000)
                waiting.cancel()
                let cancelled: Bool
                do { _ = try await waiting.value; cancelled = false } catch { cancelled = error is CancellationError }
                blocker.cancel()
                _ = try? await blocker.value
                let freed = try await single.run { true }
                expect(cancelled && freed, "a waiting job can be cancelled and slots come back")
            }
            // The star button stars through a signed-in gh and opens GitHub otherwise.
            do {
                let suite = "LimeStarChecks-" + UUID().uuidString
                let store = UserDefaults(suiteName: suite)!
                defer { store.removePersistentDomain(forName: suite) }
                let log = root.appendingPathComponent("gh-args.txt")
                func fakeGH(_ name: String, exit code: Int) throws -> String {
                    let script = root.appendingPathComponent(name)
                    try "#!/bin/sh\nprintf '%s ' \"$@\" > '\(log.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                    return script.path
                }
                let good = try fakeGH("gh-good", exit: 0), bad = try fakeGH("gh-bad", exit: 1)
                let plain = root.appendingPathComponent("gh-plain")
                try "".write(to: plain, atomically: true, encoding: .utf8)
                expect(GitHubStar.cli(in: [root.appendingPathComponent("none").path, plain.path, good])?.path == good, "star finds an executable gh")
                var opened: [URL] = []
                let star = await GitHubStar(defaults: store, locations: [good], openPage: { opened.append($0) })
                await star.star()
                let args = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                let starredState = await star.state
                expect(starredState == .starred && opened.isEmpty && args == "api --method PUT user/starred/LumenJSN/Lime --silent " && store.bool(forKey: "starredOnGitHub"),
                       "star with signed-in gh stars without opening the browser (\(args))")
                let again = await GitHubStar(defaults: store, locations: [], openPage: { opened.append($0) })
                let rememberedState = await again.state
                await again.star()
                expect(rememberedState == .starred && opened.isEmpty, "a given star is remembered")
                store.removeObject(forKey: "starredOnGitHub")
                let failing = await GitHubStar(defaults: store, locations: [bad], openPage: { opened.append($0) })
                await failing.star()
                let failingState = await failing.state
                let missing = await GitHubStar(defaults: store, locations: [], openPage: { opened.append($0) })
                await missing.star()
                let missingState = await missing.state
                expect(failingState == .openedPage && missingState == .openedPage && opened == [GitHubStar.page, GitHubStar.page] && !store.bool(forKey: "starredOnGitHub"),
                       "star without gh, or when it fails, opens GitHub instead")
            }
            expect(LimeTool.extraTools(for: ["png"]).contains(.copyText) && LimeTool.extraTools(for: ["pdf", "jpg"]) == [.copyText] && LimeTool.extraTools(for: ["mp3"]).isEmpty, "extra tool rules")
            if BackgroundRemoval.isAvailable {
                let subject = root.appendingPathComponent("subject.jpg")
                try ImageIOKit.writeImageIO(renderSubject(), to: subject, format: "jpg", quality: 0.95, metadata: [:])
                await check("remove background", .removeBackground, [subject], verify: { r in
                    let image = try ImageIOKit.load(r[0])
                    guard r[0].pathExtension == "png", let corner = alpha(image, x: 2, y: 2), let centre = alpha(image, x: image.width / 2, y: image.height / 2),
                          corner < 20, centre > 230 else { throw LimeError("background not transparent") }
                })
            }
            let qr = try ImageTools.readQRCodes(fx["qr"]!)
            if qr == ["https://example.com/lime"] { passed += 1; print("ok   read QR") } else { failed.append("read QR: \(qr)") }
        } catch {
            failed.append("fixtures: \(error.localizedDescription)")
        }
        print("PASSED \(passed) tool checks")
        for f in failed { print("FAIL " + f) }
        exit(failed.isEmpty ? 0 : 1)
    }

    static func makeTar(at url: URL, name: String) throws {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ string: String, at offset: Int) { for (n, byte) in string.utf8.enumerated() { header[offset + n] = byte } }
        put(name, at: 0); put("0000644\0", at: 100); put("0000000\0", at: 108); put("0000000\0", at: 116)
        put("00000000004\0", at: 124); put("00000000000\0", at: 136)
        for i in 148..<156 { header[i] = 32 }
        header[156] = 48; put("ustar\0", at: 257); put("00", at: 263)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum) + "\0 ", at: 148)
        var data = Data(header); data.append(Data("evil".utf8)); data.append(Data(repeating: 0, count: 508 + 1024))
        try data.write(to: url)
    }

    static func await_hasAudio(_ url: URL) throws -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = true
        Task.detached { result = (try? await FFmpeg.probe(url).hasAudio) ?? true; semaphore.signal() }
        semaphore.wait()
        return result
    }

    static func makeFixtures(_ root: URL) async throws -> [String: URL] {
        var f: [String: URL] = [:]
        let dir = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func image(_ name: String, _ color: CGColor) throws -> URL {
            let ctx = ImageIOKit.makeContext(width: 320, height: 200)!
            ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            for i in 0..<40 { ctx.setFillColor(CGColor(gray: CGFloat(i % 7) / 7, alpha: 1)); ctx.fill(CGRect(x: i * 8, y: (i * 37) % 180, width: 8, height: 20)) }
            let url = dir.appendingPathComponent(name)
            try ImageIOKit.writeImageIO(ctx.makeImage()!, to: url, format: url.pathExtension == "jpg" ? "jpg" : "png", quality: 0.95,
                                        metadata: [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifUserComment as String: "fixture"],
                                                   kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "TestCam"]])
            return url
        }
        f["jpg"] = try image("photo.jpg", CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
        f["png"] = try image("shot.png", CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        f["png2"] = try image("shot2.png", CGColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1))
        let ffmpeg = try BundledTool.url("ffmpeg")
        let wav = dir.appendingPathComponent("voice.wav")
        try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=0.5", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=0.5",
                                             "-filter_complex", "[1:a]aformat=channel_layouts=stereo:sample_rates=44100[s];[0:a][s][2:a]concat=n=3:v=0:a=1", wav.path])
        f["wav"] = wav
        let mp3 = dir.appendingPathComponent("song.mp3")
        try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-i", wav.path, "-c:a", "libmp3lame", "-b:a", "192k", mp3.path])
        f["mp3"] = mp3
        for (name, color) in [("clip.mp4", "testsrc"), ("clip2.mp4", "testsrc2")] {
            let url = dir.appendingPathComponent(name)
            try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "\(color)=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=600:duration=2",
                                                 "-c:v", "h264_videotoolbox", "-b:v", "1500k", "-c:a", "aac", "-shortest", "-pix_fmt", "yuv420p", url.path])
            f[name == "clip.mp4" ? "mp4" : "mp4b"] = url
        }
        let pdf = dir.appendingPathComponent("doc.pdf")
        try DocumentRenderer.renderPDF(NSAttributedString(string: String(repeating: "Lime PDF sample text. ", count: 400), attributes: [.font: NSFont.systemFont(ofSize: 12)]), to: pdf)
        f["pdf"] = pdf
        let big = ImageIOKit.makeContext(width: 2400, height: 1600)!
        for i in 0..<300 { big.setFillColor(CGColor(red: CGFloat(i % 13) / 13, green: CGFloat(i % 7) / 7, blue: CGFloat(i % 5) / 5, alpha: 1)); big.fillEllipse(in: CGRect(x: (i * 97) % 2400, y: (i * 53) % 1600, width: 160, height: 160)) }
        let photoPDF = dir.appendingPathComponent("scan.pdf")
        try ImageIOKit.writePDF([big.makeImage()!], to: photoPDF, dpi: 300)
        f["photoPDF"] = photoPDF
        let zip = dir.appendingPathComponent("bundle.zip")
        let ctx = try OperationContext(outputDirectory: dir, optionsForFormat: defaults)
        try await ArchiveTranscoder.create([f["jpg"]!, pdf], format: "zip", destination: zip, workspace: ctx.workspace)
        f["zip"] = zip
        // QR fixture via CoreImage.
        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/lime".utf8), "inputCorrectionLevel": "M"])!
        let qrImage = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let cg = CIContext().createCGImage(qrImage, from: qrImage.extent)!
        let qr = dir.appendingPathComponent("qr.png")
        try ImageIOKit.writeImageIO(ImageIOKit.flattened(cg), to: qr, format: "png", quality: 1, metadata: [:])
        f["qr"] = qr
        return f
    }

    static func renderTextImage(_ lines: [String]) throws -> CGImage {
        let (w, h) = (1400, 360)
        guard let ctx = ImageIOKit.makeContext(width: w, height: h, opaque: true) else { throw LimeError("context") }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 60, y: h - 140 - i * 130), withAttributes: [.font: NSFont.systemFont(ofSize: 72, weight: .medium), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw LimeError("render") }
        return image
    }

    /// A shaded ball on a plain backdrop, which Vision treats as a subject.
    static func renderSubject() throws -> CGImage {
        let (w, h) = (800, 600)
        guard let ctx = ImageIOKit.makeContext(width: w, height: h, opaque: true) else { throw LimeError("context") }
        ctx.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0.62, blue: 0.2, alpha: 1), CGColor(red: 0.75, green: 0.25, blue: 0, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300)); ctx.clip()
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 360, y: 360), startRadius: 10, endCenter: CGPoint(x: 400, y: 300), endRadius: 170, options: [])
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { throw LimeError("render") }
        return image
    }

    static func alpha(_ image: CGImage, x: Int, y: Int) -> Int? {
        guard let ctx = ImageIOKit.makeContext(width: 1, height: 1) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return ctx.data.map { Int($0.load(fromByteOffset: 3, as: UInt8.self)) }
    }
}
