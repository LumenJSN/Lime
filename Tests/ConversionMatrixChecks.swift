import AppKit
import PDFKit
import AVFoundation

/// Runs every conversion route whose source can be generated locally.
/// RAR, PPT and XLS samples come from Tests/Fixtures (see its README).
@main
enum ConversionMatrixChecks {
    static let options: @Sendable (String) -> ConvertPrefs = { _ in ConvertPrefs() }

    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LimeMatrix-" + UUID().uuidString, isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["KEEP"] == nil { try? fm.removeItem(at: root) } }
        let only = ProcessInfo.processInfo.environment["ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        var fixtures: [String: URL] = [:]
        do { fixtures = try await makeFixtures(root) } catch { print("FIXTURE FAILURE: \(error.localizedDescription)"); exit(1) }
        var passed = 0, failed: [String] = [], skipped: [String] = []
        for source in FormatCatalog.allInputFormats {
            if let only, !only.contains(source) { continue }
            guard let fixture = fixtures[source] else { skipped.append(source); continue }
            for target in FormatCatalog.targets(for: source) {
                let out = root.appendingPathComponent("out-\(source)-\(target)", isDirectory: true)
                try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                do {
                    let context = try OperationContext(outputDirectory: out, optionsForFormat: options)
                    let results = try await ConversionEngine.convert([fixture], to: target, context: context)
                    try verify(results, target: target)
                    passed += 1
                } catch {
                    failed.append("\(source)→\(target): \(error.localizedDescription.prefix(240))")
                }
            }
        }
        if only == nil || only!.contains("pages") {
            do { try await pagesListCheck(root); passed += 0 } catch { failed.append("pages lists: \(error.localizedDescription)") }
        }
        print("PASSED \(passed) routes")
        if !skipped.isEmpty { print("SKIPPED: \(skipped.joined(separator: ", "))") }
        for f in failed { print("FAIL " + f) }
        if ProcessInfo.processInfo.environment["KEEP"] != nil { print("Kept: \(root.path)") }
        exit(failed.isEmpty ? 0 : 1)
    }

    /// Every list restarts at 1 and each list paragraph carries its level.
    static func pagesListCheck(_ root: URL) async throws {
        var doc = SemanticDocument()
        let run = { (t: String) in [SemanticDocument.Inline.run(.init(text: t))] }
        doc.blocks = [.paragraph(run("Intro")), .listItem(ordered: true, level: 0, run("One")), .listItem(ordered: true, level: 0, run("Two")),
                      .listItem(ordered: false, level: 0, run("Dot")), .listItem(ordered: false, level: 1, run("Nested")), .paragraph(run("End"))]
        let out = root.appendingPathComponent("lists.pages")
        try await PagesWriter.write(doc, to: out, preview: nil, workspace: root)
        let objects = try IWAFile.read(try Process.runData("/usr/bin/unzip", ["-p", out.path, "Index/Document.iwa"]))
        guard let storage = objects.first(where: { $0.types.first == 2001 && (try? Proto.parse($0.payloads[0]))?.first(where: { $0.number == 3 })?.data.map { String(decoding: $0, as: UTF8.self).hasPrefix("Intro") } == true }) else {
            throw LimeError("storage missing")
        }
        let fields = try Proto.parse(storage.payloads[0])
        func table(_ n: Int) -> [[UInt64]] {
            (fields.first { $0.number == n }?.fields ?? []).compactMap(\.fields).map { $0.compactMap(\.uint) }
        }
        let starts = table(14).filter { $0.count == 3 && $0[1] == 1 }.map { $0[0] }
        guard starts == [6, 14] else { throw LimeError("list starts \(table(14))") }
        guard table(6).contains(where: { $0 == [18, 1, 0] }) else { throw LimeError("nested level \(table(6))") }
    }

    static func verify(_ results: [URL], target: String) throws {
        guard let url = results.first else { throw LimeError("no output") }
        var files = [url]
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            guard !files.isEmpty else { throw LimeError("empty folder") }
        }
        for file in files {
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0 else { throw LimeError("empty output \(file.lastPathComponent)") }
            switch target {
            case "jpg", "png", "heic", "tiff", "bmp", "avif", "webp":
                guard let s = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceCreateImageAtIndex(s, 0, nil) != nil else { throw LimeError("unreadable image") }
            case "pdf":
                guard let d = PDFDocument(url: file), d.pageCount > 0 else { throw LimeError("unreadable pdf") }
            case "docx", "xlsx", "pptx", "epub", "ods", "zip", "pages":
                let list = try Process.run("/usr/bin/unzip", ["-tq", file.path])
                guard list.contains("No errors") else { throw LimeError("bad zip: \(list)") }
                if target == "pages" {
                    let iwa = try Process.runData("/usr/bin/unzip", ["-p", file.path, "Index/Document.iwa"])
                    let objects = try IWAFile.read(iwa)
                    guard objects.contains(where: { $0.types.first == 2001 }) else { throw LimeError("pages without text storage") }
                }
            default: break
            }
        }
    }

    static func makeFixtures(_ root: URL) async throws -> [String: URL] {
        var f: [String: URL] = [:]
        let ctxOut = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: ctxOut, withIntermediateDirectories: true)
        func convert(_ src: URL, _ target: String) async throws -> URL {
            let context = try OperationContext(outputDirectory: ctxOut, optionsForFormat: options)
            return try await ConversionEngine.convert([src], to: target, context: context)[0]
        }
        // Image
        let png = ctxOut.appendingPathComponent("photo.png")
        let ctx = ImageIOKit.makeContext(width: 320, height: 200)!
        ctx.setFillColor(CGColor(red: 0.36, green: 0.72, blue: 0.05, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 40, y: 40, width: 120, height: 80))
        try ImageIOKit.writeImageIO(ctx.makeImage()!, to: png, format: "png", quality: 1, metadata: [:])
        f["png"] = png
        for t in ["jpg", "webp", "heic", "tiff", "avif", "bmp"] { f[t] = try await convert(png, t) }
        let svg = ctxOut.appendingPathComponent("vector.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#5cb80d"/><circle cx="60" cy="40" r="25" fill="white"/></svg>"##.write(to: svg, atomically: true, encoding: .utf8)
        f["svg"] = svg
        // Audio / video
        let ffmpeg = try BundledTool.url("ffmpeg")
        let wav = ctxOut.appendingPathComponent("tone.wav")
        _ = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-ac", "2", wav.path])
        f["wav"] = wav
        for t in ["mp3", "m4a", "flac", "ogg", "opus", "aiff", "wma"] { f[t] = try await convert(wav, t) }
        let mp4 = ctxOut.appendingPathComponent("clip.mp4")
        _ = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=600:duration=2",
                                                 "-c:v", "h264_videotoolbox", "-b:v", "800k", "-c:a", "aac", "-shortest", "-pix_fmt", "yuv420p", mp4.path])
        f["mp4"] = mp4
        for t in ["mov", "mkv", "avi", "wmv", "gif"] { f[t] = try await convert(mp4, t) }
        // Lime never writes WEBM, so the fixture comes straight from FFmpeg.
        let webm = ctxOut.appendingPathComponent("clip.webm")
        _ = try await ProcessRunner.run(ffmpeg, ["-v", "error", "-y", "-i", mp4.path, "-c:v", "libvpx-vp9", "-b:v", "400k", "-c:a", "libopus", webm.path])
        f["webm"] = webm
        // Documents
        let txt = ctxOut.appendingPathComponent("notes.txt")
        try "Lime Notes\n\nFirst paragraph with 한글 text.\n\nSecond paragraph.\n".write(to: txt, atomically: true, encoding: .utf8)
        f["txt"] = txt
        let md = ctxOut.appendingPathComponent("readme.md")
        try "# Title\n\nSome **bold** and *italic* text.\n\n- one\n- two\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n".write(to: md, atomically: true, encoding: .utf8)
        f["md"] = md
        f["docx"] = try await convert(md, "docx")
        let rich = NSAttributedString(string: "Rich text clipping\nLine two", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let rtf = ctxOut.appendingPathComponent("rich.rtf")
        try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        f["rtf"] = rtf
        let rtfd = ctxOut.appendingPathComponent("rich.rtfd")
        try rich.fileWrapper(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]).write(to: rtfd, options: .atomic, originalContentsURL: nil)
        f["rtfd"] = rtfd
        let clip = ctxOut.appendingPathComponent("snippet.textClipping")
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": "Clipped text 한글"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: clip)
        f["textClipping"] = clip
        f["epub"] = try await convert(md, "epub")
        f["pdf"] = try await convert(md, "pdf")
        f["pptx"] = try await convert(f["pdf"]!, "pptx")
        // Spreadsheets
        let csv = ctxOut.appendingPathComponent("table.csv")
        try "Name,Count,Note\nApple,3,\"red, sweet\"\nLime,12,green\n".write(to: csv, atomically: true, encoding: .utf8)
        f["csv"] = csv
        for t in ["xlsx", "ods", "tsv"] { f[t] = try await convert(csv, t) }
        // Subtitles
        let srt = ctxOut.appendingPathComponent("captions.srt")
        try "1\n00:00:01,250 --> 00:00:03,500\nFirst cue\n\n2\n00:00:04,000 --> 00:00:06,000\n한글 subtitle\n".write(to: srt, atomically: true, encoding: .utf8)
        f["srt"] = srt
        f["vtt"] = try await convert(srt, "vtt")
        // Archives
        let zipContext = try OperationContext(outputDirectory: ctxOut, optionsForFormat: options)
        let zipURL = ctxOut.appendingPathComponent("bundle.zip")
        try await ArchiveTranscoder.create([txt, png], format: "zip", destination: zipURL, workspace: zipContext.workspace)
        f["zip"] = zipURL
        f["tar"] = try await convert(zipURL, "tar")
        f["gz"] = try await convert(zipURL, "gz")
        // Optional externally supplied samples for formats that cannot be generated locally.
        for (key, variable) in [("rar", "RAR_FIXTURE"), ("xls", "XLS_FIXTURE"), ("ppt", "PPT_FIXTURE")] {
            if let path = ProcessInfo.processInfo.environment[variable] { f[key] = URL(fileURLWithPath: path) }
        }
        f["pages"] = try await convert(docxPath(f), "pages")
        return f
    }
    static func docxPath(_ f: [String: URL]) -> URL { f["docx"]! }
}

extension Process {
    static func runData(_ path: String, _ args: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
