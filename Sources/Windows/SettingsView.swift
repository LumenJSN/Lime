import AppKit
import SwiftUI

/// Settings window with one tab per area.
struct SettingsRootView: View {
    @ObservedObject var settings: AppSettings
    @State private var tab: Tab
    @State private var error: String?

    init(settings: AppSettings, initialTab: Tab = .general) {
        self.settings = settings
        _tab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general = "Basics", formats = "Outputs", compatibility = "Conversions", folders = "Access", about = "About Lime"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .general: "switch.2"; case .formats: "doc.badge.gearshape"; case .compatibility: "arrow.triangle.swap"; case .folders: "lock.open"; case .about: "leaf" }
        }
    }

    static let contentSize = NSSize(width: 456, height: 560)

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { item in
                page(item)
                    .tabItem { Label(item.rawValue, systemImage: item.symbol) }
                    .tag(item)
            }
        }
        .modifier(ClassicTabs())
        .padding(.top, 10)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(nsColor: Brand.accent))
        .alert("Couldn’t change this setting", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private func page(_ item: Tab) -> some View {
        switch item {
        case .general: SettingsScroll { GeneralSettings(settings: settings, error: $error) }
        case .formats: FormatSettings(settings: settings).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
        case .compatibility: SettingsScroll { CompatibilitySettings() }
        case .folders: SettingsScroll { FolderSettings(settings: settings) }
        case .about: AboutSettings()
        }
    }
}

/// Scrolling settings page.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Section title outside a rounded, lightly filled box.
struct SettingsSection<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(title).font(.system(size: 11.5, weight: symbol == nil ? .regular : .semibold))
            }.padding(.leading, 10)
            VStack(alignment: .leading, spacing: spacing) { content }
                .font(.system(size: 13))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
        .padding(.bottom, 16)
    }
}

/// Classic tab bar on top of a bordered box (`NSTabView`), not toolbar tabs.
struct ClassicTabs: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.tabViewStyle(.grouped) } else { content }
    }
}

/// Pop-up button with a lime title. The menu is a real `NSMenu` so the
/// button can keep its own look.
struct TintedPopup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var symbol: ((Value) -> String?)? = nil
    var fill = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 8) {
                if let symbol = symbol?(selection) { Text(symbol).font(.system(size: 13, weight: .medium)) }
                Text(options.first { $0.0 == selection }?.1 ?? "").lineLimit(1)
                if fill { Spacer(minLength: 8) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: Brand.accent))
            .padding(.horizontal, 11).frame(height: 24)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: Brand.accent).opacity(0.13)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fill, vertical: true)
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private func showMenu() {
        let menu = NSMenu()
        let target = PopupTarget { index in selection = options[index].0 }
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: [symbol?(option.0), option.1].compactMap { $0 }.joined(separator: "  "), action: #selector(PopupTarget.choose(_:)), keyEquivalent: "")
            item.tag = index
            item.target = target
            item.state = option.0 == selection ? .on : .off
            menu.addItem(item)
        }
        let current = menu.items.first { $0.state == .on }
        objc_setAssociatedObject(menu, &PopupTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil)
    }
}

final class PopupTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let handler: (Int) -> Void
    init(_ handler: @escaping (Int) -> Void) { self.handler = handler }
    @objc func choose(_ sender: NSMenuItem) { handler(sender.tag) }
}

/// Small tinted push button ("Reset", "Add Folder…").
struct TintedButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).foregroundStyle(Color(nsColor: Brand.accent).opacity(enabled ? 1 : 0.45))
                .padding(.horizontal, 10).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: Brand.accent).opacity(0.12)))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

/// Orange segmented control (Glass/Solid, Balanced/Strong).
struct TintedSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    /// Narrow segments for long rows such as crop ratios.
    var compact = false
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Text(label).font(.system(size: compact ? 12 : 13, weight: value == selection ? .medium : .regular)).lineLimit(1).fixedSize()
                        .foregroundStyle(value == selection ? Color.white : Color.primary)
                        .padding(.horizontal, compact ? 8 : 12).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(value == selection ? Color(nsColor: Brand.accent) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == selection ? .isSelected : [])
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @Binding var error: String?

    var body: some View {
        SettingsSection(title: "Appearance") {
            HStack(spacing: 8) {
                Text("Style")
                TintedSegments(title: "Style", selection: $settings.glass, options: [(true, "Glass"), (false, "Solid")])
                Spacer()
            }.frame(height: 38)
        }
        SettingsSection(title: "Basics") {
            Toggle("Launch at login", isOn: Binding(get: { settings.startAtLogin }, set: { value in
                do { try settings.setLaunchAtLogin(value) } catch { self.error = error.localizedDescription }
            })).toggleStyle(.checkbox).frame(height: 37)
            Divider()
            Toggle("Click sound and trackpad tap", isOn: $settings.feedback).toggleStyle(.checkbox).frame(height: 37)
            Toggle("Extra tools: Copy Text and Remove Background", isOn: $settings.extraTools).toggleStyle(.checkbox).frame(height: 37)
                .help("Adds on-device text recognition and background removal after the standard tools.")
            Divider()
            Text("Drag Modifiers").font(.system(size: 11.5, weight: .semibold)).padding(.top, 12).padding(.bottom, 4)
            modifierRow("Convert wheel", mode: .convert)
            modifierRow("Tools wheel", mode: .tools)
            modifierRow("Actions wheel", mode: .actions)
            Text("While you drag, tap one of these keys to call up its wheel.").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.top, 4).padding(.bottom, 12)
            Divider()
            HStack(spacing: 10) {
                Text("Dropping on the Shelf")
                TintedPopup(title: "Dropping on the Shelf", selection: $settings.shelfDropRule,
                            options: [(.newShelf, "Open a new shelf"), (.appendShelf, "Add to the open shelf")])
                Spacer()
            }.frame(height: 45)
            Divider()
            HStack(spacing: 10) {
                Text("Terminal app")
                TintedPopup(title: "Terminal app", selection: $settings.terminal, options: ShellApp.allCases.map { ($0, $0.name) })
                Spacer()
            }.frame(height: 45)
        }
    }

    private func modifierRow(_ title: String, mode: WheelMode) -> some View {
        HStack(spacing: 10) {
            Text(title)
            TintedPopup(title: title, selection: Binding(get: { settings.combination(for: mode) }, set: { value in
                let others = WheelMode.allCases.filter { $0 != mode }.map(settings.combination(for:))
                guard !others.contains(value) else { error = "\(value.names) is already used by another wheel. Choose a different combination first."; return }
                switch mode { case .convert: settings.conversions = value; case .tools: settings.tools = value; case .actions: settings.actions = value }
            }), options: KeyChord.choices.map { ($0, $0.names) }, symbol: { $0.symbols }, fill: true)
        }.frame(height: 36)
    }
}
