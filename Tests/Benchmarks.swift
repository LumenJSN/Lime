import AppKit
import PDFKit

/// Times conversions and tools on realistic files. Run through bench.sh,
/// which builds with -O. Each case runs twice: the first run includes
/// one-off costs (first ffmpeg launch, Vision model load), the second doesn't.
@main
enum Benchmarks {
    static let defaults: @Sendable (String) -> ConvertPrefs = { _ in ConvertPrefs() }
    typealias Job = (OperationContext) async throws -> [URL]

    static func main() {
        Task.detached { await run() }
        RunLoop.main.run()
    }

    /// Runs `body` as a run-loop callout instead of a main-queue job. Spinning
    /// the run loop inside a main-queue job never drains the main queue, so the
    /// wheel's timers and animation endings would never arrive.
    static func onRunLoop<T: Sendable>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { done in
            RunLoop.main.perform { done.resume(returning: MainActor.assumeIsolated(body)) }
        }
    }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let fixtures = URL(fileURLWithPath: env["BENCH_FIXTURES"] ?? fm.temporaryDirectory.appendingPathComponent("LimeBenchFixtures").path, isDirectory: true)
        let only = env["ONLY"].map { $0.split(separator: ",").map(String.init) }
        let fx: Fixtures
        do { fx = try await Fixtures.make(in: fixtures) } catch { print("FAIL fixtures: \(error.localizedDescription)"); exit(1) }

        var rows: [String] = ["case\tfirst_s\twarm_s\toutput_bytes"]
        var failed = 0
        if only == nil || only!.contains("wheel") {
            for (name, first, warm) in await onRunLoop({ wheelTimings(fx) }) {
                rows.append("\(name)\t\(fmt(first))\t\(fmt(warm))\t0")
                print("PASS bench \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) first \(ms(first))  median \(ms(warm))")
            }
        }
        for (name, job) in cases(fx) {
            if let only, !only.contains(where: { name.contains($0) }) { continue }
            do {
                let (first, _) = try await timed(job)
                let (warm, bytes) = try await timed(job)
                rows.append("\(name)\t\(fmt(first))\t\(fmt(warm))\t\(bytes)")
                print("PASS bench \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) first \(fmt(first))s  warm \(fmt(warm))s  \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
            } catch {
                failed += 1
                print("FAIL bench \(name): \(error.localizedDescription.prefix(200))")
            }
        }
        if let out = env["BENCH_OUT"] { try? rows.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8) }
        exit(failed == 0 ? 0 : 1)
    }

    static func fmt(_ seconds: Double) -> String { String(format: "%.3f", seconds) }
    static func ms(_ seconds: Double) -> String { String(format: "%.1fms", seconds * 1000) }

    /// Main-thread cost of the wheel: building and drawing it, moving the
    /// highlight, switching wheels, and how long it lingers after a drag ends.
    /// Liquid Glass is composited by the window server, so this measures the
    /// app's share of each frame, not the glass itself.
    @MainActor static func wheelTimings(_ fx: Fixtures) -> [(String, Double, Double)] {
        _ = NSApplication.shared
        let settings = AppSettings(defaults: UserDefaults(suiteName: "LimeBench-\(UUID().uuidString)")!)
        settings.feedback = false
        let controller = WheelController(settings: settings)
        let files = [fx.jpg12]
        let point = NSPoint(x: 600, y: 500)
        func panel() -> NSWindow? { NSApp.windows.first { $0 is WheelPanel && $0.isVisible } }
        func clock(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            // SwiftUI applies state changes in a run-loop pass; take one, then draw.
            RunLoop.main.run(mode: .default, before: Date())
            panel()?.contentView?.layoutSubtreeIfNeeded()
            panel()?.displayIfNeeded()
            CATransaction.flush()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        func settle(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

        let firstShow = clock { controller.show(files: files, mode: .convert, at: point) }
        settle()
        var shows: [Double] = []
        for _ in 0..<15 {
            controller.dismiss(); settle()
            shows.append(clock { controller.show(files: files, mode: .convert, at: point) })
            settle(0.05)
        }
        settle()
        var hovers: [Double] = []
        let directions = [CGPoint(x: 0, y: -100), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: -100, y: 0)]
        for i in 0..<40 { hovers.append(clock { controller.hover(directions[i % 4]) }) }
        var modes: [Double] = []
        for i in 0..<12 { modes.append(clock { controller.setMode(i % 2 == 0 ? .tools : .convert) }) }
        // Lingering: from the end of a drag without a drop until the wheel is gone.
        var lingers: [Double] = []
        for _ in 0..<3 {
            controller.show(files: files, mode: .convert, at: point); settle()
            let start = DispatchTime.now().uptimeNanoseconds
            controller.dragEnded()
            let deadline = Date().addingTimeInterval(5)
            while panel()?.isVisible == true, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            lingers.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        // The app builds the wheel at launch, so the first drag finds it ready.
        controller.dismiss(); settle()
        let launched = WheelController(settings: settings)
        launched.prewarm(); settle()
        let prewarmedShow = clock { launched.show(files: files, mode: .convert, at: point) }
        launched.dismiss(); settle()
        return [("wheel show+draw", firstShow, median(shows)),
                ("wheel first show after prewarm", prewarmedShow, prewarmedShow),
                ("wheel highlight change", hovers[0], median(hovers)),
                ("wheel mode switch", modes[0], median(modes)),
                ("wheel close after drag end", lingers[0], median(lingers))]
    }

    /// Runs one job in a fresh output folder and returns seconds and total output size.
    static func timed(_ job: Job) async throws -> (Double, Int) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("LimeBench-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let context = try OperationContext(outputDirectory: out, optionsForFormat: defaults)
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await job(context)
        let elapsed = clock.now - start
        guard !results.isEmpty else { throw LimeError("no output") }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds, results.reduce(0) { $0 + size(of: $1) })
    }

    static func size(of url: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return ImageTools.fileSize(url)
        }
        let nested = items.compactMap { ($0 as? URL).map(ImageTools.fileSize) }.reduce(0, +)
        return nested > 0 ? nested : ImageTools.fileSize(url)
    }

    static func cases(_ fx: Fixtures) -> [(String, Job)] {
        func convert(_ files: [URL], _ target: String) -> Job { { try await ConversionEngine.convert(files, to: target, context: $0) } }
        func tool(_ tool: LimeTool, _ files: [URL], _ configure: @escaping (inout ToolChoices) -> Void = { _ in }) -> Job {
            { context in
                var options = ToolChoices()
                configure(&options)
                return try await ToolEngine.run(tool, files: files, options: options, context: context)
            }
        }
        return [
            // Video
            ("convert mkv1080→mp4", convert([fx.mkv1080], "mp4")),
            ("convert mov4k→mp4", convert([fx.mov4k], "mp4")),
            ("convert hevc4k→mov", convert([fx.hevc4k], "mov")),
            ("convert mp4-1080→mp3", convert([fx.mp4_1080], "mp3")),
            ("convert mov4k→mkv", convert([fx.mov4k], "mkv")),
            ("convert mp4-1080→gif", convert([fx.mp4Short], "gif")),
            ("tool compress mp4-1080", tool(.compress, [fx.mp4_1080]) { $0.sizeGoal = .preset }),
            ("tool trim mov4k 10s", tool(.cutVideo, [fx.mov4k]) { $0.cutStart = 5; $0.cutLength = 10 }),
            ("tool join 2×mp4-1080", tool(.stitchVideos, [fx.mp4_1080, fx.mp4_1080b])),
            ("tool snapshots 5 frames", tool(.grabFrames, [fx.mp4_1080]) { $0.frameGrabTimes = [1, 5, 10, 20, 40] }),
            // Audio
            ("convert wav10m→mp3", convert([fx.wav10m], "mp3")),
            ("convert wav10m→flac", convert([fx.wav10m], "flac")),
            ("tool compress wav10m", tool(.compress, [fx.wav10m]) { $0.sizeGoal = .preset }),
            ("tool normalize wav10m", tool(.levelAudio, [fx.wav10m])),
            // Images
            ("convert jpg12mp→png", convert([fx.jpg12], "png")),
            ("convert jpg12mp→heic", convert([fx.jpg12], "heic")),
            ("convert jpg12mp→webp", convert([fx.jpg12], "webp")),
            ("convert heic12mp→jpg", convert([fx.heic12], "jpg")),
            ("convert batch 20 jpg→heic", convert(fx.batch, "heic")),
            ("tool compress jpg12mp to 50%", tool(.compress, [fx.jpg12]) { $0.sizeGoal = .percentage; $0.shrinkPercent = 50 }),
            ("tool compress jpg12mp to 300KB", tool(.compress, [fx.jpg12]) { $0.sizeGoal = .fileSize; $0.goalSizeText = "300"; $0.goalSizeUnit = "KB" }),
            ("tool compress png12mp", tool(.compress, [fx.png12]) { $0.sizeGoal = .preset }),
            ("tool batch 20 jpg compress", tool(.compress, fx.batch) { $0.sizeGoal = .preset }),
            ("tool remove background", tool(.removeBackground, [fx.jpg12])),
            ("tool images→pdf 20 jpg", tool(.imagesToPDF, fx.batch)),
            // PDF and text
            ("convert pdf50→jpg", convert([fx.pdf50], "jpg")),
            ("convert pdf50→docx", convert([fx.pdf50], "docx")),
            ("tool compress pdf50", tool(.compress, [fx.pdf50]) { $0.sizeGoal = .preset }),
            ("tool merge 2×pdf50", tool(.combinePDFs, [fx.pdf50, fx.pdf50b])),
            ("ocr text image", { _ in _ = try TextRecognition.text(in: fx.textImage); return [fx.textImage] }),
            ("convert md→docx", convert([fx.markdown], "docx")),
        ]
    }
}

/// Large, realistic inputs, generated once and reused between runs.
struct Fixtures {
    let mkv1080, mov4k, hevc4k, mp4_1080, mp4_1080b, mp4Short, wav10m: URL
    let jpg12, heic12, png12, textImage, pdf50, pdf50b, markdown: URL
    let batch: [URL]

    static func make(in dir: URL) async throws -> Fixtures {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ffmpeg = try BundledTool.url("ffmpeg")
        func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
        func ensure(_ name: String, _ make: (URL) async throws -> Void) async throws -> URL {
            let url = file(name)
            if !fm.fileExists(atPath: url.path) {
                print("making \(name)…")
                let temp = file("partial-" + name)
                try? fm.removeItem(at: temp)
                try await make(temp)
                try fm.moveItem(at: temp, to: url)
            }
            return url
        }
        func video(_ size: String, _ seconds: Int, codec: String, bitrate: String, to url: URL, container: String? = nil) async throws {
            var args = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=\(seconds)",
                        "-f", "lavfi", "-i", "sine=frequency=500:duration=\(seconds)",
                        "-c:v", codec, "-b:v", bitrate, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-shortest"]
            if codec == "hevc_videotoolbox" { args += ["-tag:v", "hvc1"] }
            if let container { args += ["-f", container] }
            _ = try await ProcessRunner.run(ffmpeg, args + [url.path])
        }
        let mkv = try await ensure("clip1080.mkv") { try await video("1920x1080", 60, codec: "h264_videotoolbox", bitrate: "8M", to: $0, container: "matroska") }
        let mov = try await ensure("clip4k.mov") { try await video("3840x2160", 30, codec: "h264_videotoolbox", bitrate: "40M", to: $0, container: "mov") }
        let hevc = try await ensure("clip4k-hevc.mp4") { try await video("3840x2160", 30, codec: "hevc_videotoolbox", bitrate: "25M", to: $0, container: "mp4") }
        let mp4 = try await ensure("clip1080.mp4") { try await video("1920x1080", 60, codec: "h264_videotoolbox", bitrate: "8M", to: $0, container: "mp4") }
        let mp4b = try await ensure("clip1080-b.mp4") { try await video("1920x1080", 60, codec: "h264_videotoolbox", bitrate: "8M", to: $0, container: "mp4") }
        let short = try await ensure("clip1080-5s.mp4") { try await video("1920x1080", 5, codec: "h264_videotoolbox", bitrate: "8M", to: $0, container: "mp4") }
        let wav = try await ensure("music10m.wav") {
            _ = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "aevalsrc=0.3*sin(2*PI*(220+110*sin(t/3))*t)+0.05*random(0):s=44100:d=600",
                                                     "-ac", "2", "-f", "wav", $0.path])
        }
        // A noisy 12 MP picture compresses like a real photo, unlike flat test patterns.
        let png = try await ensure("photo12mp.png") {
            _ = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=4000x3000:rate=1,noise=alls=18:allf=t",
                                                     "-frames:v", "1", "-f", "image2", "-c:v", "png", $0.path])
        }
        let jpg = try await ensure("photo12mp.jpg") { try ImageIOKit.writeImageIO(try ImageIOKit.load(png), to: $0, format: "jpg", quality: 0.92, metadata: [:]) }
        let heic = try await ensure("photo12mp.heic") { try ImageIOKit.writeImageIO(try ImageIOKit.load(png), to: $0, format: "heic", quality: 0.9, metadata: [:]) }
        let batchDir = dir.appendingPathComponent("batch", isDirectory: true)
        try fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
        var batch: [URL] = []
        let source = try ImageIOKit.load(png)
        for i in 1...20 {
            let url = batchDir.appendingPathComponent(String(format: "photo-%02d.jpg", i))
            if !fm.fileExists(atPath: url.path) {
                try ImageIOKit.writeImageIO(ImageIOKit.resized(source, maxDimension: 3000 + i * 20), to: url, format: "jpg", quality: 0.9, metadata: [:])
            }
            batch.append(url)
        }
        let text = try await ensure("text.png") { try ImageIOKit.writeImageIO(try textPicture(), to: $0, format: "png", quality: 1, metadata: [:]) }
        let pdf = try await ensure("report50.pdf") { try writePDF(pages: 50, photo: try ImageIOKit.load(jpg, maxPixelSize: 1600), to: $0) }
        let pdfB = try await ensure("report50-b.pdf") { try writePDF(pages: 50, photo: try ImageIOKit.load(jpg, maxPixelSize: 1600), to: $0) }
        let md = try await ensure("notes.md") { try markdownText().write(to: $0, atomically: true, encoding: .utf8) }
        return Fixtures(mkv1080: mkv, mov4k: mov, hevc4k: hevc, mp4_1080: mp4, mp4_1080b: mp4b, mp4Short: short, wav10m: wav,
                        jpg12: jpg, heic12: heic, png12: png, textImage: text, pdf50: pdf, pdf50b: pdfB, markdown: md, batch: batch)
    }

    static let paragraph = "Lime keeps every original untouched and writes the new file beside it. This sentence is here so each page has real text to lay out, search and recognise. "

    static func textPicture() throws -> CGImage {
        let size = NSSize(width: 2000, height: 1200)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            let style = NSMutableParagraphStyle(); style.lineSpacing = 6
            (String(repeating: paragraph, count: 8) as NSString).draw(in: rect.insetBy(dx: 80, dy: 80),
                withAttributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black, .paragraphStyle: style])
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw LimeError("text picture") }
        return cg
    }

    static func writePDF(pages: Int, photo: CGImage, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw LimeError("pdf context") }
        for page in 1...pages {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            ("Page \(page)\n\n" + String(repeating: paragraph, count: 6) as NSString).draw(in: CGRect(x: 54, y: 380, width: 504, height: 360),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            if page % 2 == 0 { pdf.draw(photo, in: CGRect(x: 54, y: 60, width: 504, height: 300)) }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    static func markdownText() -> String {
        (1...40).map { "## Section \($0)\n\n\(paragraph)**Bold** and *italic*.\n\n- one\n- two\n\n| A | B |\n| --- | --- |\n| \($0) | \($0 * 2) |\n" }.joined(separator: "\n")
    }
}
