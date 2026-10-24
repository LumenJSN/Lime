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

/// The wheel: glass, frosted or solid petals, a lime highlight and a round
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
                liquidGlass
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
        .animation(.spring(response: 0.24, dampingFraction: 0.74), value: model.presented)
        .animation(liquid ? .spring(response: 0.26, dampingFraction: 0.72) : .easeOut(duration: 0.09), value: model.selected)
        .animation(.easeInOut(duration: 0.22), value: model.mode)
    }

    private var dark: Bool { scheme == .dark }
    private var labelColor: Color { dark ? .white : Color(white: 0.12) }
    /// Petals and hub are Liquid Glass pieces rather than painted shapes.
    private var liquid: Bool { model.glass && model.liquid && SurfaceStyle.liquidAvailable }

    private var discFill: Color { dark ? Color(white: 0.13) : Color(white: 0.88) }

    /// Solid ring, or a frosted disc that follows light and dark mode.
    /// The Liquid Glass wheel has no disc; its petals are the glass.
    @ViewBuilder private var backdrop: some View {
        if !liquid {
            ZStack {
                if model.glass {
                    GlassBackdrop(shape: Circle(), liquid: false, material: .popover).frame(width: g.disc * 2, height: g.disc * 2)
                } else {
                    Circle().fill(discFill).frame(width: g.disc * 2, height: g.disc * 2)
                }
                Circle().strokeBorder(Color(nsColor: Brand.accent).opacity(0.35), lineWidth: 1)
                    .frame(width: g.disc * 2, height: g.disc * 2)
            }
        }
    }

    @ViewBuilder private var liquidGlass: some View {
        if liquid, #available(macOS 26.0, *) {
            LiquidPetals(count: model.items.count, selected: model.selected, hubDiameter: g.hole * 2 - 4, geometry: g)
        }
    }

    private var petalFill: Color {
        if !model.glass { return dark ? Color(white: 0.24) : Color.white }
        return dark ? Color.white.opacity(0.1) : Color.white.opacity(0.5)
    }

    private var hubFill: Color {
        if liquid { return .clear }
        if model.glass { return dark ? Color.black.opacity(0.3) : Color.white.opacity(0.7) }
        return dark ? Color(white: 0.18) : Color(white: 0.96)
    }

    /// Soft halo that keeps labels crisp over whatever the glass refracts.
    private var labelHalo: Color {
        guard liquid else { return .clear }
        return dark ? Color.black.opacity(0.45) : Color.white.opacity(0.7)
    }

    private var selectedFill: LinearGradient {
        let lime = Color(nsColor: Brand.accent)
        return LinearGradient(colors: [lime.opacity(0.82), lime], startPoint: .top, endPoint: .bottom)
    }

    private func petal(index: Int, item: WheelItem) -> some View {
        let active = model.selected == index
        let count = model.items.count
        let shape = PetalShape(index: index, count: count)
        let lift = liquid && active ? g.lift(index, of: count) : .zero
        let label = g.labelCenter(index, of: count).applying(CGAffineTransform(translationX: lift.x, y: lift.y))
        let textColor: Color = active ? .white : labelColor
        return ZStack {
            // Liquid Glass petals, highlight included, are drawn by LiquidPetals.
            if !liquid {
                shape.fill(active ? AnyShapeStyle(selectedFill) : AnyShapeStyle(petalFill))
                if active { shape.stroke(Color.white.opacity(0.5), lineWidth: 1) }
            }
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
        .shadow(color: active ? .clear : labelHalo, radius: liquid ? 1.5 : 0)
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
            .background(Circle().fill(hubFill))
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
                if model.glass { GlassBackdrop(shape: shape, liquid: liquid, material: .popover) } else { shape.fill(discFill) }
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

/// Fill that makes a transparent window's pixels receive mouse and drag
/// events: about one 8-bit step, too faint to see even over white.
enum HitCatcher { static let alpha = 0.005 }

/// See-through backdrop that blurs whatever sits behind it, so file names
/// underneath never compete with the labels: Liquid Glass when chosen and
/// available (macOS 26 and later), a behind-window blur otherwise.
struct GlassBackdrop<S: Shape>: View {
    let shape: S
    var tint: Color = .clear
    var liquid = true
    /// Blur used when Liquid Glass is off or unavailable.
    var material: NSVisualEffectView.Material = .hudWindow
    var body: some View {
        if liquid, #available(macOS 26.0, *) {
            // Glass alone leaves the window's pixels transparent, which lets
            // clicks and drags fall through to the window below.
            shape.fill(Color.black.opacity(HitCatcher.alpha))
                .glassEffect(.regular, in: shape).overlay(shape.fill(tint))
        } else {
            VisualEffectBlur(material: material).clipShape(shape).overlay(shape.fill(tint))
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
