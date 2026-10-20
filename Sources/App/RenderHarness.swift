import AppKit
import SwiftUI

/// `--render <dir>`: draws the wheel and windows offscreen to PNG files so
/// layouts can be reviewed without screen-recording permission.
@MainActor
enum RenderHarness {
    static func run(delegate: AppDelegate, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = delegate.settings
        var jobs: [(String, AnyView, CGSize, Double)] = []
        let photo = directory.appendingPathComponent("fixture-photo.jpg")
        makePhoto(photo)
        let audio = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_AUDIO"] ?? "/System/Library/Sounds/Glass.aiff")
        func wheel(_ files: [URL], _ mode: WheelMode, selected: Int?, glass: Bool = true, dark: Bool = false) -> AnyView {
            let model = WheelModel()
            model.items = WheelCatalog.items(for: files, mode: mode)
            model.mode = mode
            model.selected = selected
            model.glass = glass
            model.idleLabel = "2.4 MB"
            model.presented = true
            return AnyView(WheelView(model: model).background(dark ? Color(white: 0.12) : Color(white: 0.96)).environment(\.colorScheme, dark ? .dark : .light))
        }
        let wav = URL(fileURLWithPath: "/tmp/sample.wav")
        jobs.append(("wheel-convert-audio", wheel([wav], .convert, selected: nil), CGSize(width: 340, height: 340), 0.3))
        jobs.append(("wheel-convert-audio-selected", wheel([wav], .convert, selected: 6), CGSize(width: 340, height: 340), 0.3))
        jobs.append(("wheel-tools-photo", wheel([photo], .tools, selected: 2), CGSize(width: 340, height: 340), 0.3))
        jobs.append(("wheel-actions", wheel([photo], .actions, selected: nil), CGSize(width: 340, height: 340), 0.3))
        jobs.append(("wheel-three", wheel([URL(fileURLWithPath: "/tmp/a.srt")], .convert, selected: 0), CGSize(width: 340, height: 340), 0.3))
        jobs.append(("wheel-solid-dark", wheel([photo], .convert, selected: 1, glass: false, dark: true), CGSize(width: 340, height: 340), 0.3))
        for tab in SettingsRootView.Tab.allCases {
            jobs.append(("settings-\(tab.rawValue.lowercased())", AnyView(SettingsTabHost(settings: settings, tab: tab)), CGSize(width: 456, height: 560), 0.4))
        }
        jobs.append(("welcome", AnyView(IntroView(settings: settings, close: {}, minimize: {})), CGSize(width: 560, height: 520), 0.4))
        let progress = OperationProgressModel(title: "Converting to MP3", total: 1)
        progress.fraction = 0.6
        jobs.append(("progress", AnyView(OperationProgressView(model: progress)), CGSize(width: 290, height: 80), 0.3))
        let shelf = ShelfModel()
        shelf.items = [photo, audio]
        jobs.append(("shelf", AnyView(ShelfView(model: shelf)), CGSize(width: 320, height: 300), 1.0))
        for tool in [LimeTool.compress, .adjustPhoto, .markUpPhoto, .addBackdrop, .cropPhoto, .maskPhoto, .stripTags] {
            let model = ToolEditorModel(tool: tool, files: [photo], settings: settings)
            if tool == .markUpPhoto {
                var a = Markup(kind: .arrow, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 600, y: 400)); a.lineWidth = 10
                model.options.annotations = [a]
            }
            jobs.append(("tool-\(tool.rawValue)", AnyView(ToolWindowContent(model: model, apply: {}, cancel: {})), ToolWindowController.size(for: tool), 1.5))
        }
        for tool in [LimeTool.levelAudio, .cutAudio, .censorAudio, .remixChannels] {
            let model = ToolEditorModel(tool: tool, files: [audio], settings: settings)
            jobs.append(("tool-\(tool.rawValue)", AnyView(ToolWindowContent(model: model, apply: {}, cancel: {})), ToolWindowController.size(for: tool), 2.0))
        }
        // With RENDER_FIXTURES, every editor is drawn from real sample files.
        if let folder = ProcessInfo.processInfo.environment["RENDER_FIXTURES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            jobs.removeAll { $0.0.hasPrefix("tool-") }
            let f = { (name: String) in folder.appendingPathComponent(name) }
            let specs: [(String, LimeTool, [URL])] = [
                ("img_compress", .compress, [f("photo.png")]), ("img_metadata", .stripTags, [f("photo.png")]), ("img_edit", .adjustPhoto, [f("photo.png")]),
                ("img_annotate", .markUpPhoto, [f("photo.png")]), ("img_addbg", .addBackdrop, [f("photo.png")]), ("img_crop", .cropPhoto, [f("photo.png")]),
                ("img_redact", .maskPhoto, [f("photo.png")]), ("aud_normalize", .levelAudio, [f("song.wav")]), ("aud_visualize", .waveVideo, [f("song.wav")]),
                ("aud_trim", .cutAudio, [f("song.wav")]), ("aud_channels", .remixChannels, [f("song.wav")]), ("aud_bleep", .censorAudio, [f("song.wav")]),
                ("vid_trim", .cutVideo, [f("clip.mov")]), ("vid_crop", .cropClip, [f("clip.mov")]), ("vid_speed", .retimeVideo, [f("clip.mov")]),
                ("vid_snapshot", .grabFrames, [f("clip.mov")]), ("vid_split", .sliceVideo, [f("clip.mov")]), ("vid_redact", .maskVideo, [f("clip.mov")]),
                ("pdf_organize", .arrangePages, [f("doc.pdf")]), ("imgs_collage", .makeMosaic, [f("photo.png"), f("photo2.jpg")]),
                ("vids_join", .stitchVideos, [f("clip.mov"), f("clip2.mp4")]), ("pdfs_merge", .combinePDFs, [f("doc.pdf"), f("doc2.pdf")]),
            ]
            for (name, tool, files) in specs {
                let model = ToolEditorModel(tool: tool, files: files, settings: settings)
                jobs.append(("tool-" + name, AnyView(ToolWindowContent(model: model, apply: {}, cancel: {}).environment(\.colorScheme, .dark)), ToolWindowController.size(for: tool), 3.0))
            }
        }
        renderNext(jobs, directory: directory)
    }

    private static func renderNext(_ jobs: [(String, AnyView, CGSize, Double)], directory: URL) {
        guard let job = jobs.first else { NSApp.terminate(nil); return }
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: job.2), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        let host = NSHostingView(rootView: job.1.frame(width: job.2.width, height: job.2.height))
        host.frame = NSRect(origin: .zero, size: job.2)
        window.contentView = host
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + job.3) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(job.0 + ".png"))
            }
            window.orderOut(nil)
            renderNext(Array(jobs.dropFirst()), directory: directory)
        }
    }

    private static func makePhoto(_ url: URL) {
        guard let ctx = ImageIOKit.makeContext(width: 1200, height: 800) else { return }
        let colors = [CGColor(red: 0.75, green: 0.92, blue: 0.4, alpha: 1), CGColor(red: 0.36, green: 0.72, blue: 0.05, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1200, y: 800), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85)); ctx.fillEllipse(in: CGRect(x: 420, y: 220, width: 360, height: 360))
        if let image = ctx.makeImage() { try? ImageIOKit.writeImageIO(image, to: url, format: "jpg", quality: 0.9, metadata: [:]) }
    }
}

/// Settings view opened on a given tab (render only).
struct SettingsTabHost: View {
    @ObservedObject var settings: AppSettings
    let tab: SettingsRootView.Tab
    var body: some View { SettingsRootView(settings: settings, initialTab: tab) }
}
