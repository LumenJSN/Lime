import AppKit

/// `DragWatcher`: watches system drags of files and reports modifier
/// taps. The drag pasteboard's change count marks a new drag session.
@MainActor
final class DragWatcher {
    /// Live system state; tests substitute their own.
    struct Inputs {
        var buttonPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
        var modifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
        var location: () -> NSPoint = { NSEvent.mouseLocation }
        var changeCount: () -> Int = { NSPasteboard(name: .drag).changeCount }
        var files: () -> [URL] = {
            (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
    }

    var onTap: (([URL], WheelMode, NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private let settings: AppSettings
    private let inputs: Inputs
    private var monitors: [Any] = []
    private var timer: Timer?
    private var baseline: Int
    private var pressPoint: NSPoint?
    private var lastFlags: NSEvent.ModifierFlags = []
    private(set) var dragging = false
    private(set) var files: [URL] = []
    private(set) var isRunning = false

    init(settings: AppSettings, inputs: Inputs = Inputs()) {
        self.settings = settings
        self.inputs = inputs
        baseline = inputs.changeCount()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.poll() }
            return e
        }) { monitors.append(local) }
        // Button and modifier state are polled: global monitors cannot see
        // key events without Accessibility access, and drags suppress some events.
        let poll = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    func stop() {
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        isRunning = false
        reset()
    }

    private func reset() {
        let hadDrag = dragging
        dragging = false
        files = []
        pressPoint = nil
        baseline = inputs.changeCount()
        if hadDrag { onDragEnded?() }
    }

    /// One sampling step; public for tests.
    func poll() {
        let flags = inputs.modifiers().intersection(KeyChord.relevant)
        defer { lastFlags = flags }
        guard settings.monitoring, inputs.buttonPressed() else {
            // Anything on the drag pasteboard now belongs to a finished drag.
            if dragging || pressPoint != nil { reset() } else { baseline = inputs.changeCount() }
            return
        }
        if pressPoint == nil { pressPoint = inputs.location() }
        if !dragging {
            let p = inputs.location(), start = pressPoint ?? p
            if ProcessInfo.processInfo.environment["LIME_TRACE"] != nil { NSLog("[trace] pressed moved=%.0f cc=%d base=%d", hypot(p.x - start.x, p.y - start.y), inputs.changeCount(), baseline) }
            guard hypot(p.x - start.x, p.y - start.y) > 3, inputs.changeCount() != baseline else { return }
            let urls = inputs.files()
            guard !urls.isEmpty else { baseline = inputs.changeCount(); return }
            dragging = true
            files = urls
        }
        // Trigger on the transition into a configured combination.
        if ProcessInfo.processInfo.environment["LIME_TRACE"] != nil, flags != lastFlags { NSLog("[trace] flags %lu -> %lu dragging=%d", lastFlags.rawValue, flags.rawValue, dragging ? 1 : 0) }
        guard flags != lastFlags, !flags.isEmpty, let mode = settings.mode(for: flags) else { return }
        onTap?(files, mode, inputs.location())
    }
}
