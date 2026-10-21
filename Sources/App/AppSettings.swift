import AppKit
import ServiceManagement

/// A modifier combination tapped during a drag (`DragModifierCombination`).
struct KeyChord: Hashable, Codable, Sendable {
    var rawValue: UInt
    static let shift = KeyChord(flags: .shift)
    static let command = KeyChord(flags: .command)
    static let control = KeyChord(flags: .control)
    static let option = KeyChord(flags: .option)
    static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    init(flags: NSEvent.ModifierFlags) { rawValue = flags.intersection(Self.relevant).rawValue }
    init(rawValue: UInt) { self.rawValue = rawValue }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: rawValue) }

    var symbols: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
    var names: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        return parts.joined(separator: " + ")
    }
    /// Single keys first, then every two-key pair.
    static let choices: [KeyChord] = {
        let singles: [NSEvent.ModifierFlags] = [.shift, .command, .control, .option]
        var result = singles.map { KeyChord(flags: $0) }
        for i in 0..<singles.count { for j in (i + 1)..<singles.count { result.append(KeyChord(flags: [singles[i], singles[j]])) } }
        return result
    }()
}

enum ShelfDropRule: String, CaseIterable { case newShelf, appendShelf }
enum ShellApp: String, CaseIterable {
    case terminal = "com.apple.Terminal", iTerm = "com.googlecode.iterm2"
    var name: String { self == .terminal ? "Terminal" : "iTerm2" }
}

/// Look of the wheel and the shelf. Liquid Glass needs macOS 26; Frosted is
/// the blur older systems get, and Solid is opaque.
enum SurfaceStyle: String, CaseIterable, Sendable {
    case liquid, frosted, solid
    static var liquidAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static var standard: SurfaceStyle { liquidAvailable ? .liquid : .frosted }
    var title: String {
        switch self {
        case .liquid: "Liquid Glass"
        case .frosted: "Frosted"
        case .solid: "Solid"
        }
    }
    /// Choices offered in Settings on this Mac.
    static var offered: [SurfaceStyle] { liquidAvailable ? allCases : [.frosted, .solid] }
}

/// Persisted preferences (`LimeSettingsModel`).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    @Published var surface: SurfaceStyle { didSet { defaults.set(surface.rawValue, forKey: "surface"); NotificationCenter.default.post(name: .wheelThemeDidChange, object: nil) } }
    /// See-through styles; Solid is the only opaque one.
    var glass: Bool { surface != .solid }
    @Published var feedback: Bool { didSet { defaults.set(feedback, forKey: "feedback") } }
    @Published var monitoring: Bool { didSet { defaults.set(monitoring, forKey: "monitoring") } }
    /// Grab Text and Cut Out Subject in the tools wheel.
    @Published var extraTools: Bool { didSet { defaults.set(extraTools, forKey: "extraTools") } }
    @Published var conversions: KeyChord { didSet { save(conversions, "conversionsModifier") } }
    @Published var tools: KeyChord { didSet { save(tools, "toolsModifier") } }
    @Published var actions: KeyChord { didSet { save(actions, "actionsModifier") } }
    @Published var shelfDropRule: ShelfDropRule { didSet { defaults.set(shelfDropRule.rawValue, forKey: "shelfDropRule") } }
    @Published var terminal: ShellApp { didSet { defaults.set(terminal.rawValue, forKey: "terminal") } }
    @Published var outputFolder: URL? { didSet { defaults.set(outputFolder?.path, forKey: "outputFolder") } }
    @Published var formatOptions: [String: ConvertPrefs] { didSet { saveFormats() } }
    @Published var welcomeCompleted: Bool { didSet { defaults.set(welcomeCompleted, forKey: "welcomeCompleted") } }
    /// Compress-tool presets shown under Formats (`defaultImageCompression…`, `defaultVideoCompressionStrength`).
    @Published var photoSquashLevel: ToolChoices.SquashLevel { didSet { defaults.set(photoSquashLevel.rawValue, forKey: "lime.photoSquash") } }
    @Published var resizeCap: ToolChoices.ResizeCap { didSet { defaults.set(resizeCap.rawValue, forKey: "lime.resizeCap") } }
    @Published var videoSquashLevel: ToolChoices.SquashLevel { didSet { defaults.set(videoSquashLevel.rawValue, forKey: "lime.videoSquash") } }
    /// Folders the user allowed from Settings → Folders.
    @Published var allowedFolders: [String] { didSet { defaults.set(allowedFolders, forKey: "allowedFolders") } }
    @Published private(set) var startAtLogin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["glass": true, "feedback": true, "monitoring": true, "extraTools": true, "shelfDropRule": ShelfDropRule.newShelf.rawValue,
                                     "terminal": ShellApp.terminal.rawValue, "welcomeCompleted": false])
        // Older builds stored a Glass/Solid switch under "glass".
        let stored = defaults.string(forKey: "surface").flatMap(SurfaceStyle.init(rawValue:))
            ?? (defaults.bool(forKey: "glass") ? SurfaceStyle.standard : .solid)
        surface = stored == .liquid && !SurfaceStyle.liquidAvailable ? .frosted : stored
        feedback = defaults.bool(forKey: "feedback")
        monitoring = defaults.bool(forKey: "monitoring")
        extraTools = defaults.bool(forKey: "extraTools")
        func load(_ key: String, _ fallback: KeyChord) -> KeyChord {
            let raw = defaults.object(forKey: key) as? UInt
            return raw.map(KeyChord.init(rawValue:)).flatMap { $0.rawValue == 0 ? nil : $0 } ?? fallback
        }
        conversions = load("conversionsModifier", .shift)
        tools = load("toolsModifier", .command)
        actions = load("actionsModifier", .control)
        shelfDropRule = ShelfDropRule(rawValue: defaults.string(forKey: "shelfDropRule") ?? "") ?? .newShelf
        terminal = ShellApp(rawValue: defaults.string(forKey: "terminal") ?? "") ?? .terminal
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        welcomeCompleted = defaults.bool(forKey: "welcomeCompleted")
        photoSquashLevel = ToolChoices.SquashLevel(rawValue: defaults.string(forKey: "lime.photoSquash") ?? "") ?? .gentle
        resizeCap = ToolChoices.ResizeCap(rawValue: defaults.string(forKey: "lime.resizeCap") ?? "") ?? .original
        videoSquashLevel = ToolChoices.SquashLevel(rawValue: defaults.string(forKey: "lime.videoSquash") ?? "") ?? .gentle
        allowedFolders = defaults.stringArray(forKey: "allowedFolders") ?? []
        formatOptions = Self.loadFormats(defaults)
        refreshLoginItem()
    }

    private func save(_ combo: KeyChord, _ key: String) { defaults.set(combo.rawValue, forKey: key) }

    private static func loadFormats(_ defaults: UserDefaults) -> [String: ConvertPrefs] {
        guard let data = defaults.data(forKey: "formatOptions.v3"),
              let stored = try? JSONDecoder().decode([String: ConvertPrefs].self, from: data) else { return [:] }
        return stored.mapValues { $0.validated() }
    }
    private func saveFormats() {
        defaults.set(try? JSONEncoder().encode(formatOptions), forKey: "formatOptions.v3")
    }

    func options(for format: String) -> ConvertPrefs { formatOptions[format]?.validated() ?? ConvertPrefs.defaults(for: format) }
    func setOptions(_ options: ConvertPrefs, for format: String) {
        let value = options.validated()
        if value == ConvertPrefs.defaults(for: format) { formatOptions.removeValue(forKey: format) } else { formatOptions[format] = value }
    }
    func resetOptions(for format: String) { formatOptions.removeValue(forKey: format) }

    /// Snapshot safe to read from conversion tasks.
    var optionsProvider: @Sendable (String) -> ConvertPrefs {
        let snapshot = formatOptions
        return { snapshot[$0]?.validated() ?? ConvertPrefs.defaults(for: $0) }
    }

    func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        let combo = KeyChord(flags: flags)
        if combo == conversions { return .convert }
        if combo == tools { return .tools }
        if combo == actions { return .actions }
        return nil
    }

    func combination(for mode: WheelMode) -> KeyChord {
        switch mode { case .convert: conversions; case .tools: tools; case .actions: actions }
    }

    // MARK: Login item

    func refreshLoginItem() { startAtLogin = SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        refreshLoginItem()
        if enabled, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

extension Notification.Name {
    static let wheelThemeDidChange = Notification.Name("local.Lime.wheelThemeDidChange")
}

/// Shared visual constants from the asset catalog (`AccentColor` = sRGB 1, 0.3216, 0).
enum Brand {
    /// Lime green; white labels stay readable on it.
    static let accent = NSColor(srgbRed: 0.361, green: 0.722, blue: 0.051, alpha: 1)
    static let accentDeep = NSColor(srgbRed: 0.27, green: 0.6, blue: 0.04, alpha: 1)
}
