import AppKit
import Combine
import SwiftUI

/// Shared state for one tool window (`FileToolOptionsModel`).
@MainActor
final class ToolEditorModel: ObservableObject {
    let tool: LimeTool
    @Published var files: [URL]
    @Published var options = ToolChoices()
    @Published var busy = false
    @Published var message: String?
    /// Bumped by the footer's Reset button; editors clear their own state.
    @Published var resetCount = 0
    let settings: AppSettings
    init(tool: LimeTool, files: [URL], settings: AppSettings) {
        self.tool = tool; self.files = files; self.settings = settings
        options.orderedFiles = tool.isAggregate || tool == .combinePDFs ? files : nil
        let video = files.contains { FormatCatalog.category(FormatCatalog.format(of: $0) ?? "") == .video }
        options.squashLevel = video ? settings.videoSquashLevel : settings.photoSquashLevel
        options.resizeCap = settings.resizeCap
    }
    var primaryFile: URL { files[0] }

    /// Title of each window's main button.
    var applyTitle: String {
        switch tool {
        case .compress: "Compress"
        case .stripTags: "Save"
        case .adjustPhoto: "Save Copy"
        case .markUpPhoto: "Save Copy"
        case .addBackdrop: "Save Copy"
        case .maskPhoto, .maskVideo: "Save Copy"
        case .censorAudio: "Save Copy"
        case .levelAudio: "Normalize"
        case .arrangePages: "Save PDF"
        case .combinePDFs: "Merge"
        case .stitchVideos: "Join"
        case .grabFrames: options.frameGrabTimes.count == 1 ? "Save 1 Snapshot" : "Save \(options.frameGrabTimes.count) Snapshots"
        case .sliceVideo: options.clipExport == .merged && !options.droppedSlices.isEmpty ? "Export as One Video" : "Split Video"
        case .waveVideo: "Create Video"
        case .makeMosaic: "Create Collage"
        default: "Apply"
        }
    }

    /// Footer hint shown while the window cannot be applied yet.
    var footerHint: String? {
        guard !ToolValidation.canApply(self) else { return nil }
        switch tool {
        case .markUpPhoto: return "Draw something on the photo first."
        case .maskPhoto: return "Draw a box over what should be hidden."
        case .censorAudio: return "Mark at least one part to bleep."
        case .grabFrames: return "Add at least one frame."
        default: return nil
        }
    }

    var hasReset: Bool { [.markUpPhoto, .addBackdrop, .cropPhoto, .maskPhoto, .cropClip].contains(tool) }
}

/// Rounded floating panel with a close button, a centred title and an
/// apply bar along the bottom.
@MainActor
final class ToolWindowController: NSObject, NSWindowDelegate {
    let model: ToolEditorModel
    private(set) var window: NSWindow?
    private let apply: (ToolChoices, NSPoint) -> Void
    private var modeWatch: AnyCancellable?
    var onClose: (() -> Void)?

    init(tool: LimeTool, files: [URL], settings: AppSettings, apply: @escaping (ToolChoices, NSPoint) -> Void) {
        model = ToolEditorModel(tool: tool, files: files, settings: settings)
        self.apply = apply
    }

    func show(near point: NSPoint) {
        let root = ToolWindowContent(model: model, apply: { [weak self] in self?.commit() }, cancel: { [weak self] in self?.window?.close() })
        var size = Self.size(for: model.tool)
        let fits = Self.fitsContent(model.tool)
        if fits { size.height = Self.contentHeight(model: model, width: size.width) }
        // Windows keep the size set here; content never resizes them on its own.
        let host = FirstMouseHostingView(rootView: root.frame(width: size.width).frame(maxHeight: .infinity))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.title = model.tool.name
        window.identifier = NSUserInterfaceItemIdentifier("fileToolOptions")
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = host
        window.delegate = self
        window.level = .floating
        if fits {
            size.height += Self.titleBarInset(window)
            window.setContentSize(size)
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            let origin = NSPoint(x: min(max(point.x - size.width / 2, f.minX), f.maxX - size.width), y: min(max(point.y - size.height / 2, f.minY), f.maxY - size.height))
            window.setFrameOrigin(origin)
        } else { window.center() }
        self.window = window
        if fits {
            modeWatch = model.$options.map(\.sizeGoal).removeDuplicates().dropFirst()
                .sink { [weak self] _ in DispatchQueue.main.async { self?.fitHeight() } }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tools whose window height follows their controls, so the apply button
    /// sits right under them.
    static func fitsContent(_ tool: LimeTool) -> Bool { tool == .compress }

    /// Height the whole window content needs at `width`.
    static func contentHeight(model: ToolEditorModel, width: CGFloat) -> CGFloat {
        let probe = NSHostingView(rootView: ToolWindowContent(model: model, apply: {}, cancel: {})
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        return ceil(probe.fittingSize.height)
    }

    /// Height of the hidden title bar. SwiftUI lays the content out below it,
    /// so a window sized to its content needs this much more.
    static func titleBarInset(_ window: NSWindow) -> CGFloat {
        window.frame.height - window.contentLayoutRect.height
    }

    /// Resizes the window to its content, keeping the title bar in place
    /// unless that would push the bottom off screen.
    private func fitHeight() {
        guard let window else { return }
        let height = Self.contentHeight(model: model, width: window.frame.width) + Self.titleBarInset(window)
        var frame = window.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = min(visible.minY, visible.maxY - height)
        }
        if frame != window.frame { window.setFrame(frame, display: true, animate: true) }
    }

    /// Window size per tool, roomy enough for its controls.
    static func size(for tool: LimeTool) -> NSSize {
        switch tool {
        case .compress: NSSize(width: 400, height: 399)
        case .stripTags: NSSize(width: 500, height: 564)
        case .adjustPhoto: NSSize(width: 500, height: 811)
        case .markUpPhoto: NSSize(width: 460, height: 752)
        case .addBackdrop: NSSize(width: 460, height: 674)
        case .cropPhoto: NSSize(width: 420, height: 629)
        case .maskPhoto: NSSize(width: 420, height: 765)
        case .levelAudio: NSSize(width: 420, height: 635)
        case .waveVideo: NSSize(width: 420, height: 655)
        case .cutAudio: NSSize(width: 420, height: 360)
        case .remixChannels, .censorAudio: NSSize(width: 420, height: 424)
        case .cutVideo: NSSize(width: 420, height: 706)
        case .cropClip: NSSize(width: 420, height: 687)
        case .retimeVideo: NSSize(width: 420, height: 694)
        case .grabFrames: NSSize(width: 420, height: 700)
        case .sliceVideo: NSSize(width: 420, height: 612)
        case .maskVideo: NSSize(width: 420, height: 880)
        case .arrangePages: NSSize(width: 580, height: 624)
        case .makeMosaic: NSSize(width: 420, height: 720)
        case .stitchVideos, .combinePDFs, .imagesToPDF: NSSize(width: 340, height: 300)
        default: NSSize(width: 420, height: 520)
        }
    }

    private func commit() {
        let origin = window.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        apply(model.options, origin)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .toolWindowWillClose, object: model)
        onClose?()
    }
}

extension Notification.Name { static let toolWindowWillClose = Notification.Name("LimeToolWindowWillClose") }

struct ToolWindowContent: View {
    @ObservedObject var model: ToolEditorModel
    var apply: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(model.tool.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                HStack {
                    Button(action: cancel) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 24, height: 24).background(Circle().fill(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close window").accessibilityLabel("Close")
                    Spacer()
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            Divider()
            editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let hint = model.message ?? model.footerHint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if model.hasReset { EditorButton(title: "Reset") { model.resetCount += 1 } }
                    if model.tool == .stripTags {
                        EditorButton(title: "Wipe All") { model.options.wipeAllTags = true; apply() }
                            .help("Remove metadata now and save a new file. Photo cleanup includes private blocks that cannot be removed individually. The original is kept.")
                            .disabled(model.busy)
                    }
                    Spacer()
                    MainActionButton(title: model.applyTitle, enabled: ToolValidation.canApply(model) && !model.busy, action: apply)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
        }
        .tint(Color(nsColor: Brand.accent))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var editor: some View {
        switch model.tool {
        case .compress: CompressEditor(model: model)
        case .stripTags: TagsEditor(model: model)
        case .adjustPhoto: PhotoAdjustEditor(model: model)
        case .markUpPhoto: MarkupEditor(model: model)
        case .addBackdrop: FrameEditor(model: model)
        case .cropPhoto: ImageCropEditor(model: model)
        case .maskPhoto: ImageRedactionEditor(model: model)
        case .makeMosaic: MosaicEditor(model: model)
        case .levelAudio: NormalizeEditor(model: model)
        case .remixChannels: MonoStereoEditor(model: model)
        case .cutAudio: AudioCutEditor(model: model)
        case .censorAudio: BleepEditor(model: model)
        case .waveVideo: WaveVideoEditor(model: model)
        case .cutVideo: VideoCutEditor(model: model)
        case .cropClip: VideoCropEditor(model: model)
        case .retimeVideo: TempoEditor(model: model)
        case .grabFrames: FrameGrabEditor(model: model)
        case .sliceVideo: SplitVideoEditor(model: model)
        case .maskVideo: VideoRedactionEditor(model: model)
        case .stitchVideos, .combinePDFs, .imagesToPDF: SortedInputs(model: model)
        case .arrangePages: PageSorterEditor(model: model)
        default: EmptyView()
        }
    }
}

enum ToolValidation {
    @MainActor static func canApply(_ model: ToolEditorModel) -> Bool {
        let o = model.options
        switch model.tool {
        case .markUpPhoto: return !o.annotations.isEmpty
        case .maskPhoto, .maskVideo: return !o.redactions.isEmpty
        case .censorAudio: return !o.censorSpans.isEmpty
        case .grabFrames: return !o.frameGrabTimes.isEmpty
        case .sliceVideo: return !o.sliceTimes.isEmpty
        case .cropPhoto, .cropClip: return (o.cropRect?.width ?? 0) > 0.001 && (o.cropRect?.height ?? 0) > 0.001
        case .waveVideo: return o.waveLook == .waveform || o.posterURL != nil
        case .compress: return o.sizeGoal != .fileSize || o.targetBytes(original: 1) != nil
        case .stitchVideos: return (o.orderedFiles ?? model.files).count >= 2
        default: return true
        }
    }
}

// MARK: - Native editor controls

/// Orange filled button of the apply bar; grey while unavailable.
struct MainActionButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Color.white : Color.secondary.opacity(0.7))
                .padding(.horizontal, 12).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(enabled ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain).disabled(!enabled).keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("fileToolApply")
    }
}

/// Grey rounded button used inside editors ("Reset", "Faces", "Add Frame").
struct EditorButton: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(isEnabled ? 0.9 : 0.35))
            .padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Grey pop-up button used inside editors.
struct EditorPopup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        Button {
            let menu = NSMenu()
            let target = PopupTarget { index in selection = options[index].0 }
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option.1, action: #selector(PopupTarget.choose(_:)), keyEquivalent: "")
                item.tag = index; item.target = target; item.state = option.0 == selection ? .on : .off
                menu.addItem(item)
            }
            objc_setAssociatedObject(menu, &PopupTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? "").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityLabel(title).accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
    }
}

/// Label on the left, control on the right.
struct EditorRow<Control: View>: View {
    let title: String
    var secondary = false
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: secondary ? 11 : 13)).foregroundStyle(secondary ? .secondary : .primary)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 30)
    }
}

/// Capsule colour well for markup and mask colours.
struct ColorCapsule: View {
    let title: String
    @Binding var color: RGBColor
    var body: some View {
        ColorPicker(title, selection: Binding(get: { Color(cgColor: color.cgColor) }, set: { value in
            let ns = NSColor(value).usingColorSpace(.sRGB) ?? .black
            color = RGBColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
        }), supportsOpacity: false)
        .labelsHidden()
        .frame(width: 44, height: 22)
        .accessibilityLabel(title)
    }
}

/// Labeled slider row (`ToolSettingRow`): title and value above the slider.
struct ToolSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(Int($0.rounded())) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(format(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let step { Slider(value: $value, in: range, step: step).controlSize(.small).accessibilityLabel(title) }
            else { Slider(value: $value, in: range).controlSize(.small).accessibilityLabel(title) }
        }
    }
}

/// Inline slider row: title, slider, value (Add BG, Channels, Edit Photo).
struct InlineSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var captionWidth: CGFloat = 80
    var valueWidth: CGFloat = 52
    var format: (Double) -> String = { String(Int($0.rounded())) }
    var reset: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).frame(width: captionWidth, alignment: .leading)
            Slider(value: $value, in: range).controlSize(.small).accessibilityLabel(title)
            Text(format(value)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: valueWidth, alignment: .trailing)
            if let reset {
                Button(action: reset) { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reset \(title)").accessibilityLabel("Reset \(title)")
            }
        }
        .frame(minHeight: 20)
    }
}

/// Small section title inside an editor ("Light", "Redactions").
struct EditorSectionTitle: View {
    let title: String
    var body: some View { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 6) }
}

/// Dark rounded panel behind previews.
struct PeekPane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// `ToolSettingsGroup`: a titled stack without a box.
struct ToolGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorSectionTitle(title: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preview above the controls.
struct EditorSplit<Preview: View, Controls: View>: View {
    @ViewBuilder var preview: Preview
    @ViewBuilder var controls: Controls
    var body: some View {
        VStack(spacing: 10) {
            PeekPane { preview }.frame(maxHeight: .infinity).layoutPriority(1)
            ScrollView { VStack(alignment: .leading, spacing: 10) { controls }.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 300)
        }
        .padding(12)
    }
}

/// Tool windows float over Finder; the first click acts immediately.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
