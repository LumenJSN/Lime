import AppKit
import SwiftUI
import QuickLookUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class ShelfModel: ObservableObject {
    enum ShelfLayout: String { case icons, list }
    @Published var items: [URL] = []
    @Published var selection: Set<URL> = []
    @Published var shelfLayoutMode: ShelfLayout = .icons
    @Published var collapsed = false
    @Published var dropTargeted = false
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
        onResize?()
    }
    func remove(_ urls: Set<URL>) {
        items.removeAll { urls.contains($0) }
        selection.subtract(urls)
        if items.isEmpty { onClose?() } else { onResize?() }
    }
    var dragItems: [URL] { selection.isEmpty ? items : items.filter(selection.contains) }
}

/// A card that holds files, with a lime tab along its top edge.
struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @State private var band: CGRect?
    @State private var itemFrames: [URL: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                if !model.collapsed {
                    Divider().opacity(0.5)
                    content
                }
            }
            .background(card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.dropTargeted ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.1), lineWidth: model.dropTargeted ? 2 : 0.5))
            .padding(.top, 14)
            ShelfTab().frame(maxWidth: .infinity).padding(.top, 9).allowsHitTesting(false)
        }
        .padding(8)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers { if let url = await provider.loadFileURL() { urls.append(url) } }
                model.add(urls)
            }
            return true
        }
    }

    private var card: some View {
        GlassBackdrop(shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                      tint: scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.55), liquid: settings.surface == .liquid)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PileThumb(items: Array(model.items.prefix(3))).frame(width: 34, height: 30)
                .overlay(DraggedFiles(urls: { model.dragItems }))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.items.count == 1 ? model.items[0].lastPathComponent : "\(model.items.count) items")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(model.dropTargeted ? "Drop here" : "Drag out to use").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !model.collapsed {
                headerButton(model.shelfLayoutMode == .icons ? "list.bullet" : "square.grid.2x2", help: model.shelfLayoutMode == .icons ? "Show as List" : "Show as Icons") {
                    model.shelfLayoutMode = model.shelfLayoutMode == .icons ? .list : .icons; model.onResize?()
                }
            }
            headerButton(model.collapsed ? "chevron.down" : "chevron.up", help: model.collapsed ? "Unfold shelf" : "Fold shelf") {
                model.collapsed.toggle(); model.onResize?()
            }
            headerButton("xmark", help: "Close shelf (files stay where they are)") { model.onClose?() }
        }
        .padding(.leading, 52).padding(.trailing, 10).padding(.vertical, 9)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).background(Circle().fill(Color.primary.opacity(0.06)))
        }.buttonStyle(.plain).help(help)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Drag on empty space to select several items.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("floatItems")).onChanged { g in
                        let rect = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                          width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                        band = rect
                        model.selection = Set(itemFrames.filter { $0.value.intersects(rect) }.map(\.key))
                    }.onEnded { _ in band = nil })
                    .simultaneousGesture(TapGesture().onEnded { model.selection = [] })
                Group {
                    if model.shelfLayoutMode == .icons {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                            ForEach(model.items, id: \.self) { url in tile(url).background(frameReader(url)) }
                        }.padding(10)
                    } else {
                        VStack(spacing: 2) { ForEach(model.items, id: \.self) { url in row(url).background(frameReader(url)) } }.padding(6)
                    }
                }
                if let band {
                    Rectangle().fill(Color(nsColor: Brand.accent).opacity(0.15))
                        .overlay(Rectangle().strokeBorder(Color(nsColor: Brand.accent).opacity(0.8), lineWidth: 1))
                        .frame(width: band.width, height: band.height).offset(x: band.minX, y: band.minY).allowsHitTesting(false)
                }
            }
            // Fill the visible area so empty space below the files is selectable too.
            .frame(minHeight: Self.contentHeight, alignment: .topLeading)
            .coordinateSpace(name: "floatItems")
            .onPreferenceChange(FloatItemFrames.self) { itemFrames = $0 }
            .accessibilityLabel("Shelf items. Drag on empty space to pick several.")
        }
        .frame(maxHeight: Self.contentHeight)
    }

    private static let contentHeight: CGFloat = 320

    private func frameReader(_ url: URL) -> some View {
        GeometryReader { geo in Color.clear.preference(key: FloatItemFrames.self, value: [url: geo.frame(in: .named("floatItems"))]) }
    }

    private func tile(_ url: URL) -> some View {
        let selected = model.selection.contains(url)
        return VStack(spacing: 4) {
            Thumbnail(url: url, size: 54).frame(width: 58, height: 54)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color(nsColor: Brand.accent) : .clear))
        }
        .frame(width: 78)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.primary.opacity(0.08) : .clear))
        .overlay(DraggedFiles(urls: { model.selection.contains(url) ? model.dragItems : [url] }, onClick: { click(url, $0) }, onDoubleClick: { NSWorkspace.shared.open(url) }))
        .contextMenu { menu(url) }
        .accessibilityLabel("Shelf item, \(url.lastPathComponent)")
    }

    private func row(_ url: URL) -> some View {
        let selected = model.selection.contains(url)
        return HStack(spacing: 8) {
            Thumbnail(url: url, size: 22).frame(width: 24, height: 22)
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(nsColor: Brand.accent) : .clear))
        .overlay(DraggedFiles(urls: { model.selection.contains(url) ? model.dragItems : [url] }, onClick: { click(url, $0) }, onDoubleClick: { NSWorkspace.shared.open(url) }))
        .contextMenu { menu(url) }
    }

    private func click(_ url: URL, _ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) { if model.selection.contains(url) { model.selection.remove(url) } else { model.selection.insert(url) } }
        else if flags.contains(.shift), let anchor = model.items.firstIndex(where: model.selection.contains), let i = model.items.firstIndex(of: url) {
            model.selection = Set(model.items[min(anchor, i)...max(anchor, i)])
        } else { model.selection = [url] }
    }

    @ViewBuilder private func menu(_ url: URL) -> some View {
        Button("Open") { NSWorkspace.shared.open(url) }
        Button("Quick Look") { FloatQuickLook.shared.show(model.selection.contains(url) ? model.dragItems : [url]) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.selection.contains(url) ? model.dragItems : [url]) }
        Divider()
        Button("Take off shelf") { model.remove(model.selection.contains(url) ? model.selection : [url]) }
        Button("Close shelf (files stay where they are)") { model.onClose?() }
    }
}

/// Lime grip tab centred on the card's top edge.
struct ShelfTab: View {
    var body: some View {
        Capsule()
            .fill(Color(nsColor: Brand.accent))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .frame(width: 34, height: 7)
            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 0.5)
    }
}

struct PileThumb: View {
    let items: [URL]
    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated().reversed()), id: \.offset) { index, url in
                Thumbnail(url: url, size: 26).frame(width: 26, height: 26)
                    .rotationEffect(.degrees(Double(index) * 7 - 4)).offset(x: CGFloat(index) * 3)
            }
        }
    }
}

/// QuickLook thumbnail with the Finder icon as a fallback.
struct Thumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .all)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { image = rep.nsImage }
            }
    }
}


/// AppKit drag source so several files leave the card in one drag.
struct DraggedFiles: NSViewRepresentable {
    let urls: () -> [URL]
    var onClick: ((NSEvent.ModifierFlags) -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    func makeNSView(context: Context) -> DragOriginView { DragOriginView() }
    func updateNSView(_ view: DragOriginView, context: Context) {
        view.urls = urls; view.onClick = onClick; view.onDoubleClick = onDoubleClick
    }

    final class DragOriginView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onDoubleClick: (() -> Void)?
        private var downEvent: NSEvent?
        override func mouseDown(with event: NSEvent) {
            downEvent = event
            if event.clickCount == 2 { onDoubleClick?() } else { onClick?(event.modifierFlags) }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 3 else { return }
            downEvent = nil
            let items = urls().enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let p = convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(x: p.x - 24 + CGFloat(index) * 4, y: p.y - 24 - CGFloat(index) * 4, width: 48, height: 48), contents: icon)
                return item
            }
            guard !items.isEmpty else { return }
            beginDraggingSession(with: items, event: event, source: self)
        }
        override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : .copy
        }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Let right clicks reach SwiftUI's context menu.
            NSApp.currentEvent?.type == .rightMouseDown ? nil : super.hitTest(point)
        }
    }
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

@MainActor
final class FloatQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = FloatQuickLook()
    private var urls: [URL] = []
    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

/// Owns the open shelves and snaps them to screen edges.
@MainActor
final class ShelfController {
    private let settings: AppSettings
    private var shelves: [(panel: NSPanel, model: ShelfModel)] = []
    init(settings: AppSettings) { self.settings = settings }

    func add(_ files: [URL], at point: NSPoint) {
        if settings.shelfDropRule == .appendShelf, let last = shelves.last {
            last.model.add(files)
            last.panel.orderFrontRegardless()
            return
        }
        let model = ShelfModel()
        model.items = files
        let host = FirstMouseHostingView(rootView: ShelfView(model: model, settings: settings))
        let panel = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.onDragFinished = { [weak panel] in if let panel { Self.snapToEdge(panel) } }
        model.onResize = { [weak panel, weak host] in
            guard let panel, let host else { return }
            DispatchQueue.main.async {
                let size = host.fittingSize
                var frame = panel.frame
                frame.origin.y += frame.height - size.height
                frame.size = NSSize(width: max(260, min(420, size.width)), height: size.height)
                panel.setFrame(frame, display: true, animate: true)
            }
        }
        model.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated { panel.orderOut(nil); self?.shelves.removeAll { $0.panel === panel } }
            })
        }
        let size = host.fittingSize
        let frame = NSRect(x: point.x - 150, y: point.y - size.height / 2, width: 300, height: size.height)
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Key without activating the app: Space previews and the first drag works.
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        shelves.append((panel, model))
    }

    /// Snaps the shelf to the nearest screen edge when released close to it.
    static func snapToEdge(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        var frame = panel.frame
        let threshold: CGFloat = 40
        if frame.minX - f.minX < threshold { frame.origin.x = f.minX - 6 }
        else if f.maxX - frame.maxX < threshold { frame.origin.x = f.maxX - frame.width + 6 }
        else { return }
        frame.origin.y = min(max(frame.origin.y, f.minY), f.maxY - frame.height)
        panel.setFrame(frame, display: true, animate: true)
    }
}

final class FloatPanel: NSPanel {
    var onDragFinished: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); onDragFinished?() }
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp { onDragFinished?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, let view = contentView as? FirstMouseHostingView<ShelfView> {
            FloatQuickLook.shared.show(view.rootView.model.dragItems)
        } else if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) }
    }
}

private struct FloatItemFrames: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) { value.merge(nextValue()) { $1 } }
}
