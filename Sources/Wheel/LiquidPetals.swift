import SwiftUI

/// Liquid Glass wheel (macOS 26 and later): every petal and the hub is its
/// own piece of glass, and the highlighted petal is tinted lime. Labels are
/// drawn on top by `WheelView`.
@available(macOS 26.0, *)
struct LiquidPetals: View {
    let count: Int
    let selected: Int?
    let hubDiameter: CGFloat

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    Color.clear.glassEffect(style(for: index), in: PetalShape(index: index, count: count))
                }
                Color.clear.frame(width: hubDiameter, height: hubDiameter).glassEffect(.regular, in: Circle())
            }
        }
        .frame(width: WheelGeometry.canvasSide, height: WheelGeometry.canvasSide)
    }

    private func style(for index: Int) -> Glass {
        index == selected ? .regular.tint(Color(nsColor: Brand.accent)) : .regular
    }
}
