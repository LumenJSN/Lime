import SwiftUI
import AppKit

/// State shared by the SwiftUI wheel and its AppKit drop target.
@MainActor
final class WheelModel: ObservableObject {
    @Published var items: [WheelItem] = []
    @Published var mode: WheelMode = .convert
    @Published var selected: Int?
    @Published var glass = true
    /// Liquid Glass rather than the frosted blur (macOS 26 and later).
    @Published var liquid = true
    @Published var presented = false
    @Published var idleLabel = ""
    let geometry = WheelGeometry()
}

/// The wheel: a smoked disc, frosted petals, a lime highlight and a round
/// readout in the middle.
struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var scheme
    private var g: WheelGeometry { model.geometry }

    var body: some View {
        ZStack {
            if model.items.isEmpty {
                emptyLabel
            } else {
                backdrop
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    petal(index: index, item: item)
                }
                hubLabel
            }
        }
        .frame(width: WheelGeometry.canvasSide, height: WheelGeometry.canvasSide)
        .compositingGroup()
        .scaleEffect(model.presented ? 1 : 0.7)
        .rotationEffect(.degrees(model.presented ? 0 : -12))
        .opacity(model.presented ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.74), value: model.presented)
        .animation(.easeOut(duration: 0.09), value: model.selected)
        .animation(.easeInOut(duration: 0.22), value: model.mode)
    }

    private var dark: Bool { scheme == .dark }
    private var labelColor: Color { dark || model.glass ? .white : Color(white: 0.12) }

    private var discFill: Color { dark ? Color(white: 0.13) : Color(white: 0.88) }

    /// Tint over the glass, dark enough for white labels on any window.
    private var smoke: Color {
        dark ? Color.black.opacity(0.3) : Color(red: 0.1, green: 0.14, blue: 0.08).opacity(0.5)
    }

    private var backdrop: some View {
        ZStack {
            if model.glass {
                GlassBackdrop(shape: Circle(), tint: smoke, liquid: model.liquid).frame(width: g.disc * 2, height: g.disc * 2)
            } else {
                RingShape(outer: g.disc, inner: g.hole).fill(discFill, style: FillStyle(eoFill: true))
            }
            Circle().strokeBorder(Color(nsColor: Brand.accent).opacity(0.35), lineWidth: 1)
                .frame(width: g.disc * 2, height: g.disc * 2)
        }
    }

    private var petalFill: Color {
        if !model.glass { return dark ? Color(white: 0.24) : Color.white }
        return Color.white.opacity(dark ? 0.1 : 0.16)
    }

    private var selectedFill: LinearGradient {
        let lime = Color(nsColor: Brand.accent)
        return LinearGradient(colors: [lime.opacity(0.82), lime], startPoint: .top, endPoint: .bottom)
    }

    private func petal(index: Int, item: WheelItem) -> some View {
        let active = model.selected == index
        let count = model.items.count
        let shape = PetalShape(index: index, count: count)
        let label = g.labelCenter(index, of: count)
        let textColor: Color = active ? .white : labelColor
        return ZStack {
            if active { shape.fill(selectedFill) } else { shape.fill(petalFill) }
            if active { shape.stroke(Color.white.opacity(0.5), lineWidth: 1) }
            if let symbol = item.symbol {
                VStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(height: 16)
                    Text(item.title).font(.system(size: 7.5, weight: .semibold, design: .rounded)).tracking(0.3)
                        .multilineTextAlignment(.center)
                        .fixedSize()
                }
                .foregroundStyle(textColor)
                .offset(x: label.x, y: label.y)
            } else {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor)
                    .offset(x: label.x, y: label.y)
            }
        }
        .frame(width: WheelGeometry.canvasSide, height: WheelGeometry.canvasSide)
    }

    /// Round readout in the hole: the file summary, or the highlighted operation.
    @ViewBuilder private var hubLabel: some View {
        let selected = model.selected.flatMap { model.items.indices.contains($0) ? model.items[$0] : nil }
        let lines: [String] = selected.map { [$0.title.replacingOccurrences(of: "\n", with: " ")] } ?? model.idleLabel.split(separator: "\n").map(String.init)
        if !lines.isEmpty {
            let compact = lines.count > 1 || selected?.symbol != nil
            VStack(spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: compact ? 8.5 : 11, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, 8)
            .frame(width: g.hole * 2 - 4, height: g.hole * 2 - 4)
            .background(Circle().fill(dark || model.glass ? Color.black.opacity(0.35) : Color.white.opacity(0.9)))
            .id(lines.joined())
            .transition(.opacity)
        }
    }

    /// With nothing to offer the wheel collapses to a short note.
    private var emptyLabel: some View {
        Text(model.mode == .tools ? "No tools for this" : "These files have nothing in common to do")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(labelColor)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(width: 260, height: 40)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if model.glass { GlassBackdrop(shape: shape, tint: smoke, liquid: model.liquid) } else { shape.fill(discFill) }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: Brand.accent).opacity(0.35), lineWidth: 1))
    }
}

struct PetalShape: Shape {
    let index: Int, count: Int
    func path(in rect: CGRect) -> Path {
        let path = WheelGeometry().petalPath(index, of: count)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        return Path(path.copy(using: &transform) ?? path)
    }
}

struct RingShape: Shape {
    let outer: CGFloat, inner: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: rect.midX - outer, y: rect.midY - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: rect.midX - inner, y: rect.midY - inner, width: inner * 2, height: inner * 2))
        return p
    }
}

/// See-through backdrop that blurs whatever sits behind it, so file names
/// underneath never compete with the labels: Liquid Glass when chosen and
/// available (macOS 26 and later), a behind-window blur otherwise.
struct GlassBackdrop<S: Shape>: View {
    let shape: S
    let tint: Color
    var liquid = true
    var body: some View {
        if liquid, #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape).overlay(shape.fill(tint))
        } else {
            VisualEffectBlur(material: .hudWindow).clipShape(shape).overlay(shape.fill(tint))
        }
    }
}

/// Behind-window blur used for the glass style.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
