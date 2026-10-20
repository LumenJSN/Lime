import AppKit
import SwiftUI

/// `IntroView` onboarding: welcome, shortcuts, folder access, login, ready.
struct IntroView: View {
    enum Page: Int, CaseIterable { case welcome, wheel, folders, login, ready }
    @ObservedObject var settings: AppSettings
    @State private var page: Page = .welcome
    @State private var demoMode: WheelMode = .convert
    @State private var homeAccess = FolderGrants.hasHomeAccess
    @StateObject private var demo = WheelModel()
    var close: () -> Void
    var minimize: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                windowButton(color: Color(red: 1, green: 0.37, blue: 0.34), help: "Close intro", action: close)
                windowButton(color: Color(red: 1, green: 0.74, blue: 0.18), help: "Minimise intro", action: minimize)
                Spacer()
                if page != .welcome {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { page = Page(rawValue: page.rawValue - 1) ?? .welcome } } label: {
                        Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14)
            ZStack {
                switch page {
                case .welcome: welcome
                case .wheel: wheelPage
                case .folders: folders
                case .login: login
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.rawValue) { p in
                    Capsule().fill(p == page ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.15)).frame(width: p == page ? 16 : 6, height: 6)
                }
            }.padding(.bottom, 18)
        }
        .frame(width: 560, height: 520)
        .background(ZStack { VisualEffectBlur(material: .underWindowBackground); Color(nsColor: .windowBackgroundColor).opacity(0.6) })
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .tint(Color(nsColor: Brand.accent))
        .onAppear {
            demo.items = WheelCatalog.items(for: [URL(fileURLWithPath: "/tmp/photo.heic")], mode: .convert)
            demo.idleLabel = "2.4 MB"
            demo.presented = true
        }
    }

    private func windowButton(color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Circle().fill(color).frame(width: 12, height: 12) }.buttonStyle(.plain).help(help)
    }

    private func next() { withAnimation(.easeInOut(duration: 0.2)) { page = Page(rawValue: page.rawValue + 1) ?? .ready } }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 13, weight: .semibold)).frame(minWidth: 180).padding(.vertical, 4) }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.75, green: 0.92, blue: 0.4), Color(nsColor: Brand.accent)], startPoint: .top, endPoint: .bottom)).frame(width: 110, height: 110)
                Image(nsImage: StatusItemController.icon()).resizable().renderingMode(.template).foregroundStyle(.white).frame(width: 64, height: 64)
            }
            .shadow(color: Color(nsColor: Brand.accent).opacity(0.35), radius: 18, y: 8)
            Text("Welcome to Lime").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Convert, edit, and organize files without leaving the drag.\nEverything happens locally on your Mac.")
                .multilineTextAlignment(.center).font(.system(size: 14)).foregroundStyle(.secondary)
            primary("Get Started", action: next).padding(.top, 10)
        }
    }

    private var wheelPage: some View {
        VStack(spacing: 14) {
            Text("Intro").font(.system(size: 22, weight: .bold, design: .rounded))
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("First, pick up some files.").font(.system(size: 14, weight: .semibold))
                    Text("Step 2. While dragging, tap a key.").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(WheelMode.allCases, id: \.self) { mode in
                        Button {
                            demoMode = mode
                            demo.mode = mode
                            demo.items = WheelCatalog.items(for: [URL(fileURLWithPath: "/tmp/photo.heic")], mode: mode)
                            demo.selected = nil
                        } label: {
                            HStack(spacing: 10) {
                                KeyCap(text: settings.combination(for: mode).symbols, pressed: demoMode == mode)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mode == .convert ? "Conversions" : mode == .tools ? "Tools" : "Actions").font(.system(size: 12, weight: .semibold))
                                    Text(settings.combination(for: mode).names).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    Text("Step 3. Drop on the option you need.").font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 236, alignment: .leading)
                WheelView(model: demo).scaleEffect(0.68).frame(width: 232, height: 232)
                    .onContinuousHover { phase in
                        if case .active(let p) = phase {
                            demo.selected = demo.geometry.hit(CGPoint(x: (p.x - 116) / 0.68, y: (p.y - 116) / 0.68), count: demo.items.count)
                        } else { demo.selected = nil }
                    }
            }
            primary("Continue", action: next).padding(.top, 6)
        }
        .padding(.horizontal, 30)
    }

    private var folders: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 54, weight: .light)).foregroundStyle(Color(nsColor: Brand.accent))
            Text("Save Beside Your Files").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Lime saves results beside the originals. Click Allow Access to let Lime save results beside files anywhere in your home folder.")
                .multilineTextAlignment(.center).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 420)
            if homeAccess {
                Label("Home folder granted", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: Brand.accent))
                primary("Continue", action: next)
                Text("You can change this later in Settings › Access.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                primary("Grant Home Folder") {
                    if FolderGrants.requestHome() {
                        homeAccess = true
                        if !settings.allowedFolders.contains(FolderGrants.home.path) { settings.allowedFolders.append(FolderGrants.home.path) }
                    }
                }
                Button("Skip it and macOS asks once per folder instead.") { next() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var login: some View {
        VStack(spacing: 16) {
            Image(systemName: "power.circle").font(.system(size: 54, weight: .light)).foregroundStyle(Color(nsColor: Brand.accent))
            Text("Starts with your Mac.").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Launch Lime at login so the drag wheel is always one key away.").font(.system(size: 13)).foregroundStyle(.secondary)
            primary("Launch at Login") { try? settings.setLaunchAtLogin(true); next() }
            Button("Not Now") { next() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58)).foregroundStyle(Color(nsColor: Brand.accent))
            Text("Lime is ready").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Find the Lime icon near the clock in your menu bar.").font(.system(size: 13)).foregroundStyle(.secondary)
            primary("Done") { settings.welcomeCompleted = true; close() }
        }
    }
}

/// `WelcomeKeyboardKey`.
struct KeyCap: View {
    let text: String
    let pressed: Bool
    var body: some View {
        Text(text).font(.system(size: 15, weight: .medium))
            .foregroundStyle(pressed ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.7))
            .frame(minWidth: 42, minHeight: 34).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(pressed ? Color(red: 0.93, green: 0.97, blue: 0.87) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(pressed ? 0.05 : 0.14), radius: 0, y: pressed ? 1 : 3)
            .offset(y: pressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

@MainActor
final class IntroWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let onFinish: () -> Void
    init(settings: AppSettings, onFinish: @escaping () -> Void) { self.settings = settings; self.onFinish = onFinish }

    func show() {
        if window == nil {
            let panel = IntroPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.level = .normal
            panel.contentView = NSHostingView(rootView: IntroView(settings: settings, close: { [weak self] in self?.close() }, minimize: { [weak panel] in panel?.miniaturize(nil) }))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        onFinish()
    }
}

final class IntroPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
