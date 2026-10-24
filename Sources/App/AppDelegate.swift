import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    private(set) lazy var wheel = WheelController(settings: settings)
    private(set) lazy var monitor = DragWatcher(settings: settings)
    private(set) lazy var coordinator = OperationCoordinator(settings: settings)
    private var menuBar: StatusItemController?
    private var prefsWindow: NSWindow?
    private var welcome: IntroWindowController?
    private var observers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FolderGrants.restore()
        menuBar = StatusItemController(settings: settings, delegate: self)
        coordinator.onActivityChange = { [weak self] count in self?.menuBar?.setWorking(count > 0) }
        wheel.onChoose = { [weak self] operation, files, point in
            NSLog("[Lime] Drop: %@ -> %@", files.map(\.lastPathComponent).joined(separator: ", "), "\(operation)")
            // Answer Finder's drop first; work started inside the drop holds up its drag.
            DispatchQueue.main.async { self?.coordinator.perform(operation, files: files, at: point) }
        }
        monitor.onTap = { [weak self] files, mode, point in
            guard let self else { return }
            if self.wheel.isVisible { self.wheel.setMode(mode) } else { self.wheel.show(files: files, mode: mode, at: point) }
        }
        monitor.onDragEnded = { [weak self] in self?.wheel.dragEnded() }
        let arguments = CommandLine.arguments
        if !arguments.contains("--no-monitor") { monitor.start() }
        observers.append(settings.$monitoring.sink { [weak self] on in
            guard let self else { return }
            if on { self.monitor.start() } else { self.monitor.stop(); self.wheel.dismiss() }
        })
        if let index = arguments.firstIndex(of: "--render"), arguments.indices.contains(index + 1) {
            RenderHarness.run(delegate: self, directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            return
        }
        Updates.shared.start()
        DispatchQueue.main.async { [weak self] in self?.wheel.prewarm() }
        if !settings.welcomeCompleted || arguments.contains("--welcome") { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc func showSettings() {
        if prefsWindow == nil {
            let host = NSHostingView(rootView: SettingsRootView(settings: settings))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 456, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Lime Settings"
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            prefsWindow = window
        }
        settings.refreshLoginItem()
        prefsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWelcome() {
        if welcome == nil {
            welcome = IntroWindowController(settings: settings) { [weak self] in self?.welcome = nil }
        }
        welcome?.show()
    }

    @objc func toggleMonitoring() { settings.monitoring.toggle() }

    @objc func checkForUpdates() { Updates.shared.checkNow() }

    /// Opens the wheel at the pointer for files chosen in an open panel.
    @objc func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        wheel.show(files: panel.urls, mode: .convert, at: NSEvent.mouseLocation, keyboard: true)
    }

    var settingsWindowForRender: NSWindow? { prefsWindow }
}

/// `StatusItemController`: status item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: AppSettings
    private weak var delegate: AppDelegate?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggle = NSMenuItem(title: "", action: #selector(AppDelegate.toggleMonitoring), keyEquivalent: "")

    init(settings: AppSettings, delegate: AppDelegate) {
        self.settings = settings
        self.delegate = delegate
        super.init()
        item.button?.image = Self.icon()
        item.button?.toolTip = "Lime"
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        toggle.target = delegate
        menu.addItem(toggle)
        menu.addItem(.separator())
        let choose = menu.addItem(withTitle: "Choose Files…", action: #selector(AppDelegate.chooseFiles), keyEquivalent: "o")
        choose.target = delegate
        let welcome = menu.addItem(withTitle: "Intro", action: #selector(AppDelegate.showWelcome), keyEquivalent: "")
        welcome.target = delegate
        let prefs = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        prefs.target = delegate
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        updates.target = delegate
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lime", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        menuNeedsUpdate(menu)
    }

    private var working = false

    /// `Lime is working` while an operation runs, otherwise ready.
    func setWorking(_ value: Bool) {
        working = value
        item.button?.toolTip = value ? "Lime is working" : "Lime"
        if let menu = item.menu { menuNeedsUpdate(menu) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = working ? "Lime is working" : settings.monitoring ? "Lime is ready" : "Drag wheel paused"
        statusLine.image = NSImage(systemSymbolName: working ? "arrow.triangle.2.circlepath" : settings.monitoring ? "checkmark.circle" : "pause.circle",
                                   accessibilityDescription: nil)
        toggle.title = settings.monitoring ? "Pause Drag Wheel" : "Resume Drag Wheel"
    }

    /// Template glyph: a citrus slice of nine wedges around a small core.
    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: rect.midX, y: rect.midY), r = rect.width * 0.46, core = r * 0.12, gap = 0.5 as CGFloat
            context.setFillColor(NSColor.black.cgColor)
            for i in 0..<9 {
                let a0 = CGFloat(i) / 9 * 2 * .pi + .pi / 2, a1 = a0 + 2 * .pi / 9
                let mid = (a0 + a1) / 2
                let o = CGPoint(x: c.x + cos(mid) * gap, y: c.y + sin(mid) * gap)
                let path = CGMutablePath()
                path.addArc(center: o, radius: r - gap, startAngle: a0 + 0.035, endAngle: a1 - 0.035, clockwise: false)
                path.addArc(center: o, radius: core, startAngle: a1 - 0.25, endAngle: a0 + 0.25, clockwise: true)
                path.closeSubpath()
                context.addPath(path)
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lime"
        return image
    }
}
