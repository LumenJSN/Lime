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
                for radius: CGFloat in [58, 90, 124] {
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
        expect(g.hit(CGPoint(x: 70.7, y: -70.7), count: 4) == nil, "4-item gutter")
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
