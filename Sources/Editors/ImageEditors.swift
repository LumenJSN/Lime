import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Preview-sized decode plus original pixel size.
@MainActor
final class PictureSource: ObservableObject {
    @Published var preview: CGImage?
    @Published var full: CGImage?
    @Published var pixelSize = CGSize(width: 1, height: 1)
    func load(_ url: URL, keepFull: Bool = false) async {
        let result = await Task.detached { () -> (CGImage?, CGImage?) in
            let preview = try? ImageIOKit.load(url, maxPixelSize: 1600)
            let full = keepFull ? try? ImageIOKit.load(url) : nil
            return (preview, full)
        }.value
        preview = result.0
        full = result.1
        let props = ImageIOKit.properties(url)
        if let w = props[kCGImagePropertyPixelWidth as String] as? Int, let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
            pixelSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        } else if let p = result.0 { pixelSize = CGSize(width: p.width, height: p.height) }
    }
}

/// `ZoomableImagePreview`: fitted image with an overlay in view space.
struct ImageStage<Overlay: View>: View {
    let image: CGImage?
    var pixelSize: CGSize
    var zoom: CGFloat = 1
    var padding: CGFloat = 0
    var background: Color = .black
    @ViewBuilder var overlay: (CGRect) -> Overlay
    var body: some View {
        GeometryReader { geo in
            let base = aspectFitRect(pixelSize, in: geo.size, padding: padding)
            let fit = CGRect(x: base.midX - base.width * zoom / 2, y: base.midY - base.height * zoom / 2, width: base.width * zoom, height: base.height * zoom)
            ZStack(alignment: .topLeading) {
                background
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                overlay(fit)
            }
            .clipped()
        }
    }
}

extension ImageStage where Overlay == EmptyView {
    init(image: CGImage?, pixelSize: CGSize, zoom: CGFloat = 1, padding: CGFloat = 0, background: Color = .black) {
        self.init(image: image, pixelSize: pixelSize, zoom: zoom, padding: padding, background: background) { _ in EmptyView() }
    }
}

// MARK: - Edit Photo

/// `ImageAdjustmentEditor`: preview with zoom and compare, then the sliders.
struct PhotoAdjustEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var source = PictureSource()
    @State private var rendered: CGImage?
    @State private var showOriginal = false
    @State private var zoom: CGFloat = 1
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 10) {
            PeekPane {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { zoom = max(1, zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain).help("Zoom out")
                        Text("\(Int(zoom * 100))%").monospacedDigit()
                        Button { zoom = min(6, zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain).help("Zoom in")
                        Spacer()
                        Button("Reset") { model.options.photoTweaks = PhotoTweaks(); zoom = 1 }.buttonStyle(.plain)
                            .foregroundStyle(model.options.photoTweaks.isIdentity ? .tertiary : .secondary)
                        Toggle("Original", isOn: $showOriginal).toggleStyle(.button).buttonStyle(.plain)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(showOriginal ? Color(nsColor: Brand.accent) : Color.white.opacity(0.12)))
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).frame(height: 22)
                    ImageStage(image: showOriginal ? source.preview : (rendered ?? source.preview), pixelSize: source.pixelSize, zoom: zoom)
                        .onTapGesture(count: 2) { zoom = 1 }
                        .gesture(MagnificationGesture().onChanged { zoom = min(6, max(1, $0)) })
                        .accessibilityLabel("Photo preview").help("Pinch to zoom, drag to look around, double-click to fit")
                }
            }
            .frame(height: 280)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PhotoTweaks.groups, id: \.0) { group in
                        EditorSectionTitle(title: group.0)
                        ForEach(group.1, id: \.0) { item in
                            InlineSlider(title: item.0, value: Binding(get: { model.options.photoTweaks[keyPath: item.1] },
                                                                         set: { model.options.photoTweaks[keyPath: item.1] = $0 }),
                                         range: item.2, captionWidth: 92, valueWidth: 56,
                                         format: { PhotoTweaks.display(item.0, $0) },
                                         reset: { model.options.photoTweaks[keyPath: item.1] = 0 })
                        }
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .padding(12)
        .task { await source.load(model.primaryFile) }
        .onChange(of: model.options.photoTweaks) { adjustments in
            renderTask?.cancel()
            guard let preview = source.preview else { return }
            renderTask = Task {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled else { return }
                let output = await Task.detached { ImageRendering.adjust(preview, adjustments) }.value
                if !Task.isCancelled { rendered = output }
            }
        }
    }
}

// MARK: - Annotate

/// `AnnotationEditorView` with `AnnotationCanvas`.
struct MarkupEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var source = PictureSource()
    @State private var kind: Markup.Kind = .arrow
    @State private var color: RGBColor = RGBColor(hex: 0xFF3B30)
    @State private var selected: UUID?
    @State private var draft: Markup?
    @State private var dragAnchor: Markup?
    @State private var resizing: (origin: Markup, end: Bool)?
    @State private var zoomLevel: CGFloat = 2
    static let tools: [Markup.Kind] = [.arrow, .draw, .text, .rectangle, .ellipse, .highlight, .number, .magnifier, .image]

    private var pixelScale: CGFloat { max(1, source.pixelSize.width / 1200) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekPane { ImageStage(image: source.preview, pixelSize: source.pixelSize) { fit in canvas(fit) } }
                .accessibilityLabel("Markup canvas")
            HStack(spacing: 6) {
                ForEach(Self.tools, id: \.self) { k in
                    Button { kind = k; selected = nil; if k == .image { chooseImage() } } label: {
                        Image(systemName: Self.symbol(k)).font(.system(size: 13))
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .foregroundStyle(kind == k ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(kind == k ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain).help(Self.help(k)).accessibilityLabel(Self.name(k))
                }
            }
            HStack(spacing: 10) {
                ColorCapsule(title: "Color", color: Binding(get: { color }, set: { color = $0; updateSelected { $0.color = color } }))
                    .help("Markup colour")
                if let index = model.options.annotations.firstIndex(where: { $0.id == selected }), model.options.annotations[index].kind == .text {
                    TextField("Text", text: $model.options.annotations[index].text).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .accessibilityLabel("Move or change text")
                }
                if kind == .magnifier || selectedKind == .magnifier {
                    EditorPopup(title: "Loupe zoom", selection: Binding(get: { zoomLevel }, set: { z in zoomLevel = z; updateSelected { $0.zoom = z } }),
                                options: Self.zoomLevels.map { ($0, "\($0.formatted())×") })
                        .help("Loupe zoom")
                }
                Spacer()
                if kind == .draw {
                    Button("Clear Drawing") { model.options.annotations.removeAll { $0.kind == .draw }; if selectedKind == .draw { selected = nil } }
                        .controlSize(.small).help("Wipe every stroke")
                        .disabled(!model.options.annotations.contains { $0.kind == .draw })
                }
                Button { if !model.options.annotations.isEmpty { model.options.annotations.removeLast(); selected = nil } } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).help("Undo last markup").disabled(model.options.annotations.isEmpty)
                Button { deleteSelected() } label: {
                    Image(systemName: "trash").frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).help("Remove selected markup").disabled(selected == nil)
            }
            .font(.system(size: 11))
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .task { await source.load(model.primaryFile, keepFull: true) }
        .handleDeleteKey { deleteSelected() }
        .onPasteCommand(of: [.image, .fileURL]) { _ in pasteImage() }
        .background(Button("") { pasteImage() }.keyboardShortcut("v").opacity(0).allowsHitTesting(false))
        .onChange(of: model.resetCount) { _ in model.options.annotations = []; selected = nil }
    }

    static let zoomLevels: [CGFloat] = [1.5, 2, 3, 4]
    private var selectedKind: Markup.Kind? { model.options.annotations.first { $0.id == selected }?.kind }

    /// ⌘V places a copied picture in the middle, a third of the photo wide.
    private func pasteImage() {
        let board = NSPasteboard.general
        var url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL])?.first
        if url == nil, let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Lime-annotation-paste-\(UUID().uuidString).png")
            if (try? png.write(to: file)) != nil { url = file }
        }
        guard let url else { NSSound.beep(); return }
        place(url)
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.message = "Pick a picture to drop onto the photo."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(place)
    }

    private func place(_ url: URL) {
        let props = ImageIOKit.properties(url)
        let w = CGFloat(props[kCGImagePropertyPixelWidth as String] as? Int ?? 1), h = CGFloat(props[kCGImagePropertyPixelHeight as String] as? Int ?? 1)
        let width = source.pixelSize.width / 3, height = width * h / max(1, w)
        let origin = CGPoint(x: (source.pixelSize.width - width) / 2, y: (source.pixelSize.height - height) / 2)
        var a = Markup(kind: .image, start: origin, end: CGPoint(x: origin.x + width, y: origin.y + height))
        a.imageURL = url
        model.options.annotations.append(a)
        selected = a.id; kind = .image
    }

    /// Kinds whose two defining points can be dragged.
    private static func resizable(_ k: Markup.Kind) -> Bool { ![.draw, .number].contains(k) }

    /// Handle positions in pixel space; text uses its side edges.
    private static func handles(_ a: Markup) -> (CGPoint, CGPoint) {
        switch a.kind {
        case .text: let mid = a.start.y + a.fontSize * 0.6
            return (CGPoint(x: min(a.start.x, a.end.x), y: mid), CGPoint(x: max(a.start.x, a.end.x), y: mid))
        case .magnifier: return (a.end, a.end)
        default: return (a.start, a.end)
        }
    }

    private func resize(_ origin: Markup, end: Bool, to p: CGPoint) -> Markup {
        var a = origin
        switch a.kind {
        case .text:
            let left = min(origin.start.x, origin.end.x), right = max(origin.start.x, origin.end.x)
            a.start.x = end ? left : min(p.x, right - 40); a.end.x = end ? max(p.x, left + 40) : right
        case .image:
            let anchor = end ? origin.start : origin.end
            let ratio = abs(origin.end.y - origin.start.y) / max(1, abs(origin.end.x - origin.start.x))
            let width = max(16, abs(p.x - anchor.x))
            let x = end ? anchor.x + width : anchor.x - width
            let y = end ? anchor.y + width * ratio : anchor.y - width * ratio
            if end { a.end = CGPoint(x: x, y: y) } else { a.start = CGPoint(x: x, y: y) }
        case .magnifier: a.end = p
        default: if end { a.end = p } else { a.start = p }
        }
        return a
    }

    private var hint: String {
        switch kind {
        case .arrow: "Drag from where the arrow starts to where it points. Drag any markup to move it."
        case .draw: "Drag to draw. Clear Drawing wipes every stroke."
        case .highlight: "Drag over the photo to highlight."
        case .magnifier: "Set the zoom, then click a spot to drop a loupe on it."
        case .text: "Use Text for another box. Drag its edge to move it, or its side knobs to make it wider."
        case .number: "Click to drop numbered badges and drag to place them. They keep one size."
        case .image: "Use Image to pick a file or ⌘V to paste one. Drag it to move or resize."
        default: "Drag across the photo to draw. Drag any markup to move it."
        }
    }

    private func deleteSelected() { model.options.annotations.removeAll { $0.id == selected }; selected = nil }

    private func updateSelected(_ change: (inout Markup) -> Void) {
        guard let i = model.options.annotations.firstIndex(where: { $0.id == selected }) else { return }
        change(&model.options.annotations[i])
    }

    private func canvas(_ fit: CGRect) -> some View {
        let scale = fit.width / max(1, source.pixelSize.width)
        let toPixel: (CGPoint) -> CGPoint = { CGPoint(x: ($0.x - fit.minX) / scale, y: ($0.y - fit.minY) / scale) }
        let all = model.options.annotations + (draft.map { [$0] } ?? [])
        return Canvas { context, _ in
            context.withCGContext { cg in
                cg.translateBy(x: fit.minX, y: fit.minY)
                cg.scaleBy(x: scale, y: scale)
                AnnotationRenderer.draw(all, in: cg, source: source.full)
                if let s = all.first(where: { $0.id == selected }) {
                    cg.setStrokeColor(NSColor.controlAccentColor.cgColor); cg.setLineWidth(1.5 / scale); cg.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
                    cg.stroke(s.bounds.insetBy(dx: -8 / scale, dy: -8 / scale))
                    if Self.resizable(s.kind) {
                        cg.setLineDash(phase: 0, lengths: [])
                        let (h1, h2) = Self.handles(s)
                        for h in s.kind == .magnifier ? [h2] : [h1, h2] {
                            let r = 5 / scale, box = CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2)
                            cg.setFillColor(CGColor(gray: 1, alpha: 1)); cg.fillEllipse(in: box); cg.strokeEllipse(in: box)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let start = toPixel(g.startLocation), current = toPixel(g.location)
            if draft == nil, dragAnchor == nil, resizing == nil, let s = model.options.annotations.first(where: { $0.id == selected }), Self.resizable(s.kind) {
                let (h1, h2) = Self.handles(s), reach = 9 / scale
                if hypot(start.x - h2.x, start.y - h2.y) <= reach { resizing = (s, true) }
                else if s.kind != .magnifier, hypot(start.x - h1.x, start.y - h1.y) <= reach { resizing = (s, false) }
            }
            if let r = resizing, let i = model.options.annotations.firstIndex(where: { $0.id == r.origin.id }) {
                model.options.annotations[i] = resize(r.origin, end: r.end, to: current)
                return
            }
            if draft == nil, dragAnchor == nil, let hit = model.options.annotations.last(where: { $0.bounds.insetBy(dx: -14 / scale, dy: -14 / scale).contains(start) }) {
                selected = hit.id; dragAnchor = hit
            }
            if let origin = dragAnchor, let i = model.options.annotations.firstIndex(where: { $0.id == origin.id }) {
                let dx = current.x - start.x, dy = current.y - start.y
                var moved = origin
                moved.start = CGPoint(x: origin.start.x + dx, y: origin.start.y + dy)
                moved.end = CGPoint(x: origin.end.x + dx, y: origin.end.y + dy)
                moved.points = origin.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                model.options.annotations[i] = moved
                return
            }
            // `Keep annotations inside the image.`
            if draft == nil, !CGRect(origin: .zero, size: source.pixelSize).contains(start) { return }
            if draft == nil {
                var a = Markup(kind: kind, start: start, end: current)
                a.color = color; a.lineWidth = 6 * pixelScale; a.fontSize = 36 * pixelScale; a.zoom = zoomLevel
                if kind == .number { a.number = (model.options.annotations.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1 }
                if kind == .text { a.text = "Text" }
                draft = a
            }
            draft?.end = current
            if kind == .draw { draft?.points.append(current) }
        }.onEnded { _ in
            dragAnchor = nil; resizing = nil
            guard var a = draft else { return }
            draft = nil
            let tiny = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 4 / scale
            if tiny, ![.number, .magnifier, .text, .image].contains(a.kind) { return }
            if a.kind == .magnifier, tiny { a.end = CGPoint(x: a.start.x + 80 * pixelScale, y: a.start.y) }
            if a.kind == .text, tiny { a.end = CGPoint(x: a.start.x + 300 * pixelScale, y: a.start.y) }
            if a.kind == .draw, a.points.count < 2 { return }
            if a.kind == .image {
                guard let placed = placeImage(a) else { return }
                a = placed
            }
            model.options.annotations.append(a)
            selected = a.id
        })
    }

    /// Image tool: choose a picture and place it at the click, a third of the photo wide.
    private func placeImage(_ draft: Markup) -> Markup? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.message = "Choose an image to place on the photo"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let props = ImageIOKit.properties(url)
        let w = CGFloat(props[kCGImagePropertyPixelWidth as String] as? Int ?? 1), h = CGFloat(props[kCGImagePropertyPixelHeight as String] as? Int ?? 1)
        var a = draft
        let width = abs(a.end.x - a.start.x) > 8 ? abs(a.end.x - a.start.x) : source.pixelSize.width / 3
        a.start = CGPoint(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y))
        a.end = CGPoint(x: a.start.x + width, y: a.start.y + width * h / max(1, w))
        a.imageURL = url
        return a
    }

    static func symbol(_ k: Markup.Kind) -> String {
        switch k {
        case .arrow: "arrow.up.left"; case .line: "line.diagonal"; case .rectangle: "rectangle"; case .ellipse: "circle"; case .text: "textformat"
        case .draw: "pencil.tip"; case .highlight: "highlighter"; case .number: "1.circle"; case .magnifier: "plus.magnifyingglass"; case .image: "photo.badge.plus"
        }
    }
    static func name(_ k: Markup.Kind) -> String {
        switch k {
        case .arrow: "Arrow"; case .line: "Line"; case .rectangle: "Rectangle"; case .ellipse: "Ellipse"; case .text: "Text"
        case .draw: "Draw"; case .highlight: "Highlighter"; case .number: "Number"; case .magnifier: "Magnifier"; case .image: "Image"
        }
    }
    static func help(_ k: Markup.Kind) -> String { k == .arrow ? "Arrow: drag from where it starts" : name(k) }
}

// MARK: - Add BG

/// `FrameImageEditor`: live preview, background swatches and spacing.
struct FrameEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var source = PictureSource()
    @State private var rendered: CGImage?
    @State private var custom = RGBColor(r: 0.2, g: 0.42, b: 0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ImageStage(image: rendered, pixelSize: rendered.map { CGSize(width: $0.width, height: $0.height) } ?? source.pixelSize, padding: 14,
                       background: Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("backdropPreview")
            HStack(alignment: .top, spacing: 12) {
                Text("Background").font(.system(size: 11)).padding(.top, 6)
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                ForEach(FramePresets.gradients, id: \.0) { name, stops in
                                    swatch(name, fill: AnyShapeStyle(LinearGradient(colors: stops.map { Color(cgColor: RGBColor(hex: $0).cgColor) }, startPoint: .topLeading, endPoint: .bottomTrailing)))
                                }
                            }
                            HStack(spacing: 6) {
                                ForEach(FramePresets.colors, id: \.0) { name, hex in swatch(name, fill: AnyShapeStyle(Color(cgColor: RGBColor(hex: hex).cgColor))) }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(action: chooseImage) {
                            Image(systemName: "photo.badge.plus").frame(width: 28, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)))
                        }
                        .buttonStyle(.plain).help("Background image")
                        ColorCapsule(title: "Own colour", color: Binding(get: { custom }, set: { custom = $0; model.options.backdropSettings.background = .color($0) }))
                            .help("Pick background colour")
                    }
                }
            }
            InlineSlider(title: "Padding", value: $model.options.backdropSettings.padding, range: 0...400, captionWidth: 70) { "\(Int($0)) px" }
            InlineSlider(title: "Corners", value: $model.options.backdropSettings.cornerRadius, range: 0...200, captionWidth: 70) { "\(Int($0)) px" }
            InlineSlider(title: "Shadow", value: $model.options.backdropSettings.shadowRadius, range: 0...100, captionWidth: 70) { "\(Int($0)) px" }
            EditorRow(title: "Ratio", secondary: true) {
                TintedSegments(title: "Output ratio", selection: $model.options.backdropSettings.canvasShape,
                               options: BackdropSettings.CanvasShape.allCases.map { ($0, $0.label) })
            }
        }
        .padding(12)
        .task { await source.load(model.primaryFile); render() }
        .onChange(of: model.options.backdropSettings) { _ in render() }
        .onChange(of: model.resetCount) { _ in model.options.backdropSettings = BackdropSettings() }
    }

    private func swatch(_ name: String, fill: AnyShapeStyle) -> some View {
        let active = model.options.backdropSettings.background == .preset(name)
        return RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill).frame(width: 30, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(active ? Color(nsColor: Brand.accent) : Color.primary.opacity(0.12), lineWidth: active ? 2.5 : 0.5))
            .onTapGesture { model.options.backdropSettings.background = .preset(name) }
            .help(name.capitalized).accessibilityLabel("\(name.capitalized) background").accessibilityAddTraits(.isButton)
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.message = "Pick background image"
        if panel.runModal() == .OK, let url = panel.url { model.options.backdropSettings.background = .image(url) }
    }

    private func render() {
        guard let preview = source.preview else { return }
        let options = model.options.backdropSettings
        let unit = CGFloat(preview.width) / max(1, source.pixelSize.width)
        Task {
            rendered = await Task.detached { try? FrameRenderer.render(preview, options: options, maxPixels: 1600, unit: unit) }.value
        }
    }
}

// MARK: - Crop

/// `CropEditor` for images: ratio presets and exact pixel size.
struct ImageCropEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var source = PictureSource()
    @State private var aspect: CropAspect = .free
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekPane {
                ImageStage(image: source.preview, pixelSize: source.pixelSize, padding: 14) { fit in
                    CropOverlay(rect: $rect, frame: fit, lockedRatio: aspect.ratio(source: source.pixelSize), sourceSize: source.pixelSize)
                }
            }
            EditorRow(title: "Aspect ratio") {
                TintedSegments(title: "Aspect ratio", selection: Binding(get: { aspect }, set: { a in
                    aspect = a
                    rect = a == .free ? CGRect(x: 0, y: 0, width: 1, height: 1) : a.fitted(source: source.pixelSize)
                }), options: CropAspect.allCases.map { ($0, $0.rawValue) }, compact: true)
            }
            if model.files.count == 1 {
                HStack(spacing: 8) {
                    Text("W").font(.system(size: 13))
                    TextField("Crop width (px)", value: Binding(get: { Int((rect.width * source.pixelSize.width).rounded()) }, set: { w in
                        rect.size.width = min(1 - rect.minX, max(1, CGFloat(w)) / source.pixelSize.width)
                    }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 74)
                    Text("H").font(.system(size: 13))
                    TextField("Crop height (px)", value: Binding(get: { Int((rect.height * source.pixelSize.height).rounded()) }, set: { h in
                        rect.size.height = min(1 - rect.minY, max(1, CGFloat(h)) / source.pixelSize.height)
                    }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 74)
                    Text("px").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                Text("The same crop is applied to each of the \(model.files.count) images.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .task { await source.load(model.primaryFile); model.options.cropRect = rect }
        .onChange(of: rect) { model.options.cropRect = $0 }
        .onChange(of: model.resetCount) { _ in aspect = .free; rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }
}

// MARK: - Redact Photo

/// `RectangleRedactionEditor` with local face and text detection.
struct ImageRedactionEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var source = PictureSource()
    @State private var selected: UUID?
    @State private var detecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekPane {
                ImageStage(image: source.preview, pixelSize: source.pixelSize) { fit in
                    RedactionOverlay(rects: $model.options.redactions, selected: $selected, frame: fit, style: model.options.maskFill,
                                     color: model.options.maskColor)
                }
            }
            EditorRow(title: "Style", secondary: true) {
                TintedSegments(title: "Style", selection: $model.options.maskFill, options: [(.solid, "Solid"), (.blur, "Blur")])
                    .help("Blur only smudges detail. Pick Solid for anything private.")
            }
            EditorRow(title: "Color", secondary: true) { ColorCapsule(title: "Color", color: $model.options.maskColor) }
                .opacity(model.options.maskFill == .solid ? 1 : 0.4).disabled(model.options.maskFill != .solid)
            EditorRow(title: "Detect", secondary: true) {
                HStack(spacing: 8) {
                    if detecting { ProgressView().controlSize(.small) }
                    EditorButton(title: "Faces") { detect("faces") }
                    EditorButton(title: "Text") { detect("text") }
                }
                .disabled(detecting || source.preview == nil)
            }
        }
        .padding(12)
        .task { await source.load(model.primaryFile) }
        .onChange(of: model.resetCount) { _ in model.options.redactions = []; selected = nil }
    }

    private func detect(_ kind: String) {
        guard let image = source.preview else { return }
        detecting = true
        Task {
            let rects = await Task.detached { ImageRendering.detect(kind, in: image) }.value
            model.options.redactions += rects.map { MaskBox(rect: $0) }
            if rects.isEmpty { NSSound.beep() }
            detecting = false
        }
    }
}

// MARK: - Collage

/// Live mosaic preview and its layout options.
struct MosaicEditor: View {
    @ObservedObject var model: ToolEditorModel
    @State private var preview: CGImage?
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var spacingOpen = false
    @State private var orderOpen = false

    private var files: [URL] { model.options.orderedFiles ?? model.files }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ImageStage(image: preview, pixelSize: CollageRenderer.canvasSize(model.options.collage), padding: 6, background: Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(height: 300)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    EditorRow(title: "Style", secondary: true) {
                        EditorPopup(title: "Style", selection: $model.options.collage.style, options: MosaicSettings.Style.allCases.map { ($0, $0.label) })
                    }
                    if model.options.collage.style == .grid {
                        EditorRow(title: "Columns", secondary: true) {
                            HStack(spacing: 6) {
                                Text("\(model.options.collage.columns)").font(.system(size: 13)).monospacedDigit()
                                Stepper("Columns", value: $model.options.collage.columns, in: 1...max(1, files.count)).labelsHidden()
                            }
                        }
                    }
                    EditorRow(title: "Canvas", secondary: true) {
                        EditorPopup(title: "Canvas", selection: $model.options.collage.canvas, options: MosaicSettings.Canvas.allCases.map { ($0, $0.label) })
                    }
                    EditorRow(title: "Width", secondary: true) {
                        EditorPopup(title: "Image width", selection: $model.options.collage.width,
                                    options: MosaicSettings.widths.map { ($0, "\($0.formatted(.number)) px") })
                    }
                    EditorRow(title: "Image fit", secondary: true) {
                        EditorPopup(title: "Image fit", selection: $model.options.collage.fillCells, options: [(true, "Fill each tile (trims edges)"), (false, "Show whole pictures")])
                    }
                    Divider().padding(.vertical, 4)
                    DisclosureGroup("Gaps and colour", isExpanded: $spacingOpen) {
                        VStack(spacing: 6) {
                            InlineSlider(title: "Spacing", value: $model.options.collage.spacing, range: 0...0.08, captionWidth: 70) { "\(Int(($0 * Double(model.options.collage.width)).rounded())) px" }
                            InlineSlider(title: "Corners", value: $model.options.collage.cornerRadius, range: 0...0.06, captionWidth: 70) { "\(Int(($0 * Double(model.options.collage.width)).rounded())) px" }
                            EditorRow(title: "Background", secondary: true) { ColorCapsule(title: "Background", color: $model.options.collage.background) }
                        }.padding(.top, 6)
                    }
                    .font(.system(size: 11))
                    DisclosureGroup("Image order", isExpanded: $orderOpen) {
                        VStack(spacing: 4) {
                            ForEach(Array(files.enumerated()), id: \.element) { index, url in
                                HStack(spacing: 8) {
                                    Thumbnail(url: url, size: 22).frame(width: 26, height: 20)
                                    Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
                                    Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == files.count - 1)
                                }
                            }
                        }.padding(.top, 6)
                    }
                    .font(.system(size: 11))
                    HStack {
                        Spacer()
                        EditorButton(title: "Reset Layout") { model.options.collage = MosaicSettings(); model.options.orderedFiles = model.files }
                    }.padding(.top, 4)
                }
                .padding(.trailing, 6)
            }
        }
        .padding(12)
        .task { await loadThumbnails(); render() }
        .onChange(of: model.options.collage) { _ in render() }
        .onChange(of: model.options.orderedFiles) { _ in render() }
    }

    private func move(_ index: Int, _ delta: Int) {
        var list = files
        let target = index + delta
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        model.options.orderedFiles = list
    }

    private func loadThumbnails() async {
        let urls = model.files
        let loaded = await Task.detached { urls.reduce(into: [URL: CGImage]()) { $0[$1] = try? ImageIOKit.load($1, maxPixelSize: 600) } }.value
        thumbnails = loaded
    }

    private func render() {
        let images = files.compactMap { thumbnails[$0] }
        guard !images.isEmpty else { return }
        var options = model.options.collage
        options.width = 900
        Task { preview = await Task.detached { try? CollageRenderer.render(images, options: options) }.value }
    }
}
