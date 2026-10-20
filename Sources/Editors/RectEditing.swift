import SwiftUI

/// Aspect presets for image and video crops.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", sixteenNine = "16:9", nineSixteen = "9:16", fourThree = "4:3", threeFour = "3:4"
    var id: String { rawValue }
    func ratio(source: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .sixteenNine: 16.0 / 9
        case .nineSixteen: 9.0 / 16
        case .threeFour: 3.0 / 4
        }
    }
    /// Largest centred normalised rect with the pixel aspect `ratio`.
    func fitted(source: CGSize) -> CGRect {
        guard let r = ratio(source: source), source.width > 0, source.height > 0 else { return CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        let sourceRatio = source.width / source.height
        var w: CGFloat = 1, h: CGFloat = 1
        if r > sourceRatio { h = sourceRatio / r } else { w = r / sourceRatio }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

/// Fits content of `size` into `container`, returning the drawn frame.
func aspectFitRect(_ size: CGSize, in container: CGSize, padding: CGFloat = 16) -> CGRect {
    let available = CGSize(width: max(1, container.width - padding * 2), height: max(1, container.height - padding * 2))
    guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
    let scale = min(available.width / size.width, available.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

/// `CropSelection` overlay with corner/edge handles and dimming.
struct CropOverlay: View {
    @Binding var rect: CGRect            // normalised, top-left origin
    let frame: CGRect                    // drawn content frame in view space
    var lockedRatio: CGFloat?            // pixel aspect (w/h) or nil
    var sourceSize: CGSize
    @State private var start: CGRect?

    private func view(_ r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height)
    }

    var body: some View {
        let v = view(rect)
        ZStack(alignment: .topLeading) {
            Path { p in p.addRect(frame); p.addRect(v) }.fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().strokeBorder(Color(nsColor: Brand.accent), lineWidth: 2).frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                .overlay(grid(v)).contentShape(Rectangle())
                .gesture(DragGesture().onChanged { g in move(g.translation) }.onEnded { _ in start = nil })
                .accessibilityLabel("Crop area. Drag to move it.")
            ForEach(Handle.allCases, id: \.self) { h in
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Brand.accent))
                    .frame(width: h.isEdge(horizontal: true) ? 22 : (h.isEdge(horizontal: false) ? 6 : 10), height: h.isEdge(horizontal: false) ? 22 : (h.isEdge(horizontal: true) ? 6 : 10))
                    .position(h.point(in: v))
                    .accessibilityLabel(h.label).help("Pull to resize: \(h.label.lowercased().replacingOccurrences(of: "resize crop ", with: ""))")
                    .gesture(DragGesture().onChanged { g in resize(h, g.translation) }.onEnded { _ in start = nil })
            }
        }
    }

    private func grid(_ v: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = v.minX + v.width * CGFloat(i) / 3, y = v.minY + v.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: v.minY)); p.addLine(to: CGPoint(x: x, y: v.maxY))
                p.move(to: CGPoint(x: v.minX, y: y)); p.addLine(to: CGPoint(x: v.maxX, y: y))
            }
        }.stroke(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
    }

    enum Handle: CaseIterable { case tl, t, tr, r, br, b, bl, l
        /// Top/bottom edges are horizontal bars, left/right vertical.
        func isEdge(horizontal: Bool) -> Bool { horizontal ? (self == .t || self == .b) : (self == .l || self == .r) }
        var label: String {
            switch self {
            case .tl: "Resize crop top left"; case .t: "Resize crop top"; case .tr: "Resize crop top right"; case .r: "Resize crop right"
            case .br: "Resize crop bottom right"; case .b: "Resize crop bottom"; case .bl: "Resize crop bottom left"; case .l: "Resize crop left"
            }
        }
        func point(in v: CGRect) -> CGPoint {
            switch self {
            case .tl: CGPoint(x: v.minX, y: v.minY); case .t: CGPoint(x: v.midX, y: v.minY); case .tr: CGPoint(x: v.maxX, y: v.minY)
            case .r: CGPoint(x: v.maxX, y: v.midY); case .br: CGPoint(x: v.maxX, y: v.maxY); case .b: CGPoint(x: v.midX, y: v.maxY)
            case .bl: CGPoint(x: v.minX, y: v.maxY); case .l: CGPoint(x: v.minX, y: v.midY)
            }
        }
    }

    private func move(_ translation: CGSize) {
        if start == nil { start = rect }
        guard let s = start else { return }
        var r = s
        r.origin.x = min(max(0, s.minX + translation.width / frame.width), 1 - s.width)
        r.origin.y = min(max(0, s.minY + translation.height / frame.height), 1 - s.height)
        rect = r
    }

    private func resize(_ handle: Handle, _ translation: CGSize) {
        if start == nil { start = rect }
        guard let s = start else { return }
        let dx = translation.width / frame.width, dy = translation.height / frame.height
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch handle {
        case .tl: minX += dx; minY += dy
        case .t: minY += dy
        case .tr: maxX += dx; minY += dy
        case .r: maxX += dx
        case .br: maxX += dx; maxY += dy
        case .b: maxY += dy
        case .bl: minX += dx; maxY += dy
        case .l: minX += dx
        }
        minX = max(0, min(minX, maxX - 0.02)); maxX = min(1, max(maxX, minX + 0.02))
        minY = max(0, min(minY, maxY - 0.02)); maxY = min(1, max(maxY, minY + 0.02))
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio = lockedRatio, sourceSize.width > 0, sourceSize.height > 0 {
            // Normalised height that keeps the pixel ratio.
            let h = r.width * sourceSize.width / ratio / sourceSize.height
            if [.t, .b].contains(handle) {
                let w = r.height * sourceSize.height * ratio / sourceSize.width
                r.size.width = min(w, 1 - r.minX)
                r.size.height = r.width * sourceSize.width / ratio / sourceSize.height
            } else {
                r.size.height = min(h, [.tl, .tr].contains(handle) ? s.maxY : 1 - r.minY)
                r.size.width = r.height * sourceSize.height * ratio / sourceSize.width
                if [.tl, .tr].contains(handle) { r.origin.y = s.maxY - r.height }
                if [.tl, .bl, .l].contains(handle) { r.origin.x = s.maxX - r.width }
            }
        }
        rect = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// `RedactionCanvas`: draw, select, move and delete rectangles.
struct RedactionOverlay: View {
    @Binding var rects: [MaskBox]
    @Binding var selected: UUID?
    let frame: CGRect
    var visible: (MaskBox) -> Bool = { _ in true }
    var style: ToolChoices.MaskFill
    var color: RGBColor = .black
    @State private var drawing: CGRect?
    @State private var moveStart: CGRect?

    private func toNormal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - frame.minX) / frame.width)), y: min(1, max(0, (p.y - frame.minY) / frame.height)))
    }
    private func view(_ r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { g in
                    let a = toNormal(g.startLocation), b = toNormal(g.location)
                    drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                }.onEnded { _ in
                    if let r = drawing, r.width > 0.005, r.height > 0.005 {
                        let item = MaskBox(rect: r)
                        rects.append(item); selected = item.id
                    }
                    drawing = nil
                })
                .onTapGesture { selected = nil }
                .accessibilityLabel("Redaction canvas. Draw boxes over what to hide.")
            ForEach(rects.filter(visible)) { item in
                let v = view(item.rect)
                Rectangle()
                    .fill(style == .solid ? Color(cgColor: color.cgColor) : Color.white.opacity(0.18))
                    .background(style == .blur ? AnyView(VisualEffectBlur(material: .fullScreenUI)) : AnyView(EmptyView()))
                    .overlay(Rectangle().strokeBorder(selected == item.id ? Color(nsColor: Brand.accent) : Color.white.opacity(0.6), lineWidth: selected == item.id ? 2 : 1))
                    .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                    .onTapGesture { selected = item.id }
                    .gesture(DragGesture().onChanged { g in
                        guard let index = rects.firstIndex(where: { $0.id == item.id }) else { return }
                        if moveStart == nil { moveStart = rects[index].rect; selected = item.id }
                        guard let s = moveStart else { return }
                        rects[index].rect.origin = CGPoint(x: min(max(0, s.minX + g.translation.width / frame.width), 1 - s.width),
                                                           y: min(max(0, s.minY + g.translation.height / frame.height), 1 - s.height))
                    }.onEnded { _ in moveStart = nil })
                    .accessibilityLabel("Redaction box")
                if selected == item.id {
                    Circle().fill(Color(nsColor: Brand.accent)).frame(width: 12, height: 12).position(x: v.maxX, y: v.maxY)
                        .gesture(DragGesture().onChanged { g in
                            guard let index = rects.firstIndex(where: { $0.id == item.id }) else { return }
                            let p = toNormal(g.location)
                            rects[index].rect.size = CGSize(width: max(0.01, p.x - rects[index].rect.minX), height: max(0.01, p.y - rects[index].rect.minY))
                        })
                        .accessibilityLabel("Resize redaction")
                }
            }
            if let d = drawing {
                let v = view(d)
                Rectangle().strokeBorder(Color(nsColor: Brand.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY).allowsHitTesting(false)
            }
        }
        .handleDeleteKey { if let s = selected { rects.removeAll { $0.id == s }; selected = nil } }
    }
}
