import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats the wheel under the cursor.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// `WheelDropZone`: receives the in-flight Finder drag over the wheel.
@MainActor
final class WheelDropZone: NSView {
    weak var controller: WheelController?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Convert wheel")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// The window server hands drags over fully transparent pixels to the
    /// window underneath, so the whole area that selects a petal (gutters and
    /// the band past the tips included) gets a fill too faint to see.
    override func draw(_ dirtyRect: NSRect) {
        guard let geometry = controller?.model.geometry else { return }
        let radius = geometry.outer + geometry.reach
        NSColor.black.withAlphaComponent(HitCatcher.alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)).fill()
    }

    private var offsetFromCenter: (NSPoint) -> CGPoint {
        { [unowned self] p in CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY) }
    }
    private func local(_ sender: any NSDraggingInfo) -> CGPoint { offsetFromCenter(convert(sender.draggingLocation, from: nil)) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        controller?.hover(local(sender))
        return controller?.model.selected == nil ? [] : .copy
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { controller?.hover(nil) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { controller?.model.selected != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        controller?.hover(local(sender))
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return controller?.commit(files: urls.isEmpty ? nil : urls, at: NSEvent.mouseLocation) ?? false
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { controller?.dismiss() }

    // Keyboard and pointer use when the wheel is opened without a drag.
    override func mouseMoved(with event: NSEvent) { controller?.hover(offsetFromCenter(convert(event.locationInWindow, from: nil))) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseUp(with event: NSEvent) {
        controller?.hover(offsetFromCenter(convert(event.locationInWindow, from: nil)))
        if controller?.commit(files: nil, at: NSEvent.mouseLocation) != true { controller?.dismiss() }
    }
    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch event.keyCode {
        case 53: controller.dismiss()
        case 36, 76: if !controller.commit(files: nil, at: NSEvent.mouseLocation) { NSSound.beep() }
        case 123, 126: controller.step(-1)
        case 124, 125, 48: controller.step(event.modifierFlags.contains(.shift) ? -1 : 1)
        default: super.keyDown(with: event)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}

/// `ConversionOverlayController`: positions the wheel, tracks hover and
/// hands the chosen operation to the app.
@MainActor
final class WheelController {
    let model = WheelModel()
    private let settings: AppSettings
    private var panel: WheelPanel?
    private var files: [URL] = []
    private let sound = HoverChime()
    /// Bumped on every show/dismiss so a stale drag-end timer cannot close a newer wheel.
    private var generation = 0
    /// The drop arrives after the mouse-up that ends the drag, so the end of
    /// the drag only schedules the dismissal.
    nonisolated static let dropGrace: TimeInterval = 0.6
    var onChoose: ((WheelOperation, [URL], NSPoint) -> Void)?
    var isVisible: Bool { panel?.isVisible == true && model.presented }

    init(settings: AppSettings) {
        self.settings = settings
        NotificationCenter.default.addObserver(forName: .wheelThemeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySurface() }
        }
    }

    private func applySurface() {
        model.glass = settings.glass
        model.liquid = settings.surface == .liquid
    }

    func show(files: [URL], mode: WheelMode, at point: NSPoint, keyboard: Bool = false) {
        self.files = files
        let panel = self.panel ?? makePanel()
        setMode(mode)
        applySurface()
        model.idleLabel = Self.summary(files)
        if !(panel.isVisible && model.presented) {
            let size = WheelGeometry.canvasSide
            var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
                let frame = screen.frame
                origin.x = min(max(origin.x, frame.minX), frame.maxX - size)
                origin.y = min(max(origin.y, frame.minY), frame.maxY - size)
            }
            panel.setFrameOrigin(origin)
            generation += 1
            model.selected = nil
            model.presented = false
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            DispatchQueue.main.async { self.model.presented = true }
        }
        if keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView?.subviews.last)
        }
    }

    func setMode(_ mode: WheelMode) {
        guard model.mode != mode || model.items.isEmpty || model.items != WheelCatalog.items(for: files, mode: mode, extras: settings.extraTools) else { return }
        model.mode = mode
        model.items = WheelCatalog.items(for: files, mode: mode, extras: settings.extraTools)
        model.selected = nil
    }

    func hover(_ offset: CGPoint?) {
        let index = offset.flatMap { model.geometry.hit($0, count: model.items.count) }
        guard index != model.selected else { return }
        model.selected = index
        if index != nil, settings.feedback {
            sound.play()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func step(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        let count = model.items.count
        model.selected = (((model.selected ?? (delta > 0 ? -1 : 0)) + delta) % count + count) % count
        if settings.feedback { sound.play() }
    }

    /// Runs the highlighted operation. Returns false for the centre or a gutter.
    @discardableResult
    func commit(files dropped: [URL]?, at point: NSPoint) -> Bool {
        guard let index = model.selected, model.items.indices.contains(index) else { return false }
        let operation = model.items[index].operation
        let selection = dropped ?? files
        dismiss()
        onChoose?(operation, selection, point)
        return true
    }

    /// The system drag ended; close the wheel unless a drop lands first.
    func dragEnded(after delay: TimeInterval = WheelController.dropGrace) {
        let pending = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == pending else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        model.presented = false
        model.selected = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !self.model.presented { panel.orderOut(nil); panel.alphaValue = 1 }
            }
        })
    }

    private func makePanel() -> WheelPanel {
        let size = WheelGeometry.canvasSide
        let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let target = WheelDropZone(frame: container.bounds)
        target.autoresizingMask = [.width, .height]
        target.controller = self
        container.addSubview(target)
        panel.contentView = container
        self.panel = panel
        return panel
    }

    /// Centre text: the size of one file, or "2 PDF FILES" / "2 MIXED FILES"
    /// over the total size for a selection.
    static func summary(_ files: [URL]) -> String {
        guard !files.isEmpty else { return "" }
        let sizes = files.map { url -> Int64 in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            return values?.isDirectory == true ? 0 : Int64(values?.fileSize ?? 0)
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let total = formatter.string(fromByteCount: sizes.reduce(0, +))
        if files.count == 1 {
            return (try? files[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "FOLDER" : total
        }
        let formats = Set(files.map { FormatCatalog.format(of: $0) ?? "" })
        let kind = formats.count == 1 && !(formats.first ?? "").isEmpty ? FormatCatalog.label(formats.first!) : "MIXED"
        return "\(files.count) \(kind) FILES\n\(total)"
    }
}

/// A short, soft tick generated in memory.
@MainActor
final class HoverChime {
    private var sounds: [NSSound] = []
    private var next = 0
    init() {
        let data = Self.makeTick()
        sounds = (0..<4).compactMap { _ in NSSound(data: data) }
        sounds.forEach { $0.volume = 0.35 }
    }
    func play() {
        guard !sounds.isEmpty else { return }
        let sound = sounds[next]
        next = (next + 1) % sounds.count
        sound.stop()
        sound.play()
    }
    static func makeTick() -> Data {
        let rate = 44100, count = Int(Double(rate) * 0.045)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let envelope = exp(-t * 95) * min(1, t * 2000)
            let value = (sin(2 * .pi * 1850 * t) * 0.7 + sin(2 * .pi * 3700 * t) * 0.18) * envelope
            samples[i] = Int16(max(-1, min(1, value)) * 22000)
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(count * 2))
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return data
    }
}
