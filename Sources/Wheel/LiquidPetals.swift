import SwiftUI

/// Liquid Glass wheel (macOS 26 and later): every petal and the hub is its
/// own piece of glass. The highlighted petal fills with lime and lifts
/// outward, and pieces keep their identity so switching wheels morphs them
/// instead of swapping. Labels are drawn on top by `WheelView`.
@available(macOS 26.0, *)
struct LiquidPetals: View {
    let count: Int
    let selected: Int?
    let hubDiameter: CGFloat
    let geometry: WheelGeometry
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    let active = index == selected
                    let lift = active ? geometry.lift(index, of: count) : .zero
                    let shape = PetalShape(index: index, count: count)
                    // The lime lives inside the glass: macOS mutes glass tints in
                    // windows of an inactive app, which the wheel always is.
                    shape.fill(active ? AnyShapeStyle(limeFill) : AnyShapeStyle(Color.clear))
                        .glassEffect(.regular.interactive(), in: shape)
                        .glassEffectID(index, in: glass)
                        .offset(x: lift.x, y: lift.y)
                }
                Circle().fill(lime.opacity(0.14)).frame(width: hubDiameter, height: hubDiameter)
                    .glassEffect(.regular, in: Circle())
                    .glassEffectID("hub", in: glass)
            }
        }
        .frame(width: WheelGeometry.canvasSide, height: WheelGeometry.canvasSide)
    }

    private var lime: Color { Color(nsColor: Brand.accent) }

    private var limeFill: LinearGradient {
        LinearGradient(colors: [lime.opacity(0.7), lime.opacity(0.92)], startPoint: .top, endPoint: .bottom)
    }
}
