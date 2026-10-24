import AppKit

/// `DragWatcher`: watches system drags of files and reports modifier
/// taps. The drag pasteboard's change count marks a new drag session.
@MainActor
final class DragWatcher {
    /// Live system state; tests substitute their own.
    struct Inputs {
        private static let drag = NSPasteboard(name: .drag)
        var buttonPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
        var modifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
        var location: () -> NSPoint = { NSEvent.mouseLocation }
        var changeCount: () -> Int = { Inputs.drag.changeCount }
        var files: () -> [URL] = {
            (Inputs.drag.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
    }

    /// Sampling is quicker while the button is held, so a modifier tap
    /// during a drag opens the wheel sooner.
    nonisolated static let idleInterval: TimeInterval = 0.025
    nonisolated static let pressedInterval: TimeInterval = 0.008
    private static let tracing = ProcessInfo.processInfo.environment["LIME_TRACE"] != nil

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
        schedule(Self.idleInterval)
    }

    private func schedule(_ interval: TimeInterval) {
        guard isRunning, timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let poll = Timer(timeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
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
        let pressed = settings.monitoring && inputs.buttonPressed()
        schedule(pressed ? Self.pressedInterval : Self.idleInterval)
        guard pressed else {
            // Anything on the drag pasteboard now belongs to a finished drag.
            if dragging || pressPoint != nil { reset() } else { baseline = inputs.changeCount() }
            return
        }
        if pressPoint == nil { pressPoint = inputs.location() }
        if !dragging {
            let p = inputs.location(), start = pressPoint ?? p
            if Self.tracing { NSLog("[trace] pressed moved=%.0f cc=%d base=%d", hypot(p.x - start.x, p.y - start.y), inputs.changeCount(), baseline) }
            guard hypot(p.x - start.x, p.y - start.y) > 3, inputs.changeCount() != baseline else { return }
            let urls = inputs.files()
            guard !urls.isEmpty else { baseline = inputs.changeCount(); return }
            dragging = true
            files = urls
        }
        // Trigger on the transition into a configured combination.
        if Self.tracing, flags != lastFlags { NSLog("[trace] flags %lu -> %lu dragging=%d", lastFlags.rawValue, flags.rawValue, dragging ? 1 : 0) }
        guard flags != lastFlags, !flags.isEmpty, let mode = settings.mode(for: flags) else { return }
        onTap?(files, mode, inputs.location())
    }
}
