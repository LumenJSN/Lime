import CoreGraphics
import Foundation

/// Lime's wheel: a ring of petals with straight, constant-width gutters and
/// rounded corners. Petal 0 sits at twelve o'clock and the rest follow
/// clockwise. All points are offsets from the centre in y-down view space.
struct WheelGeometry: Sendable {
    static let canvasSide: CGFloat = 320
    let inner: CGFloat = 54
    let outer: CGFloat = 128
    /// Width of the gutter between neighbouring petals.
    let gap: CGFloat = 5
    let outerCorner: CGFloat = 9
    let innerCorner: CGFloat = 5
    /// Tinted disc behind the petals and the clear hole in its middle.
    var disc: CGFloat { outer + 8 }
    let hole: CGFloat = 46
    var labelRadius: CGFloat { (inner + outer) / 2 + 2 }

    /// Petal centre, in radians clockwise from north.
    func bearing(_ index: Int, of count: Int) -> CGFloat {
        2 * .pi * CGFloat(index) / CGFloat(max(1, count))
    }

    func point(radius: CGFloat, bearing: CGFloat) -> CGPoint {
        CGPoint(x: sin(bearing) * radius, y: -cos(bearing) * radius)
    }

    func labelCenter(_ index: Int, of count: Int) -> CGPoint {
        point(radius: labelRadius, bearing: bearing(index, of: count))
    }

    /// Angle that moves a point at `radius` half a gutter away from a sector edge.
    private func gutterAngle(at radius: CGFloat) -> CGFloat { asin(min(1, gap / 2 / radius)) }

    /// CGPath angle (from +x, growing clockwise on screen) for a bearing.
    private func pathAngle(_ bearing: CGFloat) -> CGFloat { bearing - .pi / 2 }

    func petalPath(_ index: Int, of count: Int) -> CGPath {
        let path = CGMutablePath()
        guard count > 1 else {
            path.addArc(center: .zero, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.move(to: CGPoint(x: inner, y: 0))
            path.addArc(center: .zero, radius: inner, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
            return path
        }
        let centre = bearing(index, of: count), half = .pi / CGFloat(count)
        let outerStart = centre - half + gutterAngle(at: outer), outerEnd = centre + half - gutterAngle(at: outer)
        let innerStart = centre - half + gutterAngle(at: inner), innerEnd = centre + half - gutterAngle(at: inner)
        let oc = min(outerCorner, (outerEnd - outerStart) * outer * 0.3)
        let ic = min(innerCorner, (innerEnd - innerStart) * inner * 0.3)

        let a = point(radius: outer, bearing: outerStart), b = point(radius: outer, bearing: outerEnd)
        let c = point(radius: inner, bearing: innerEnd), d = point(radius: inner, bearing: innerStart)
        func along(_ p: CGPoint, _ bearing: CGFloat, _ sign: CGFloat) -> CGPoint {
            CGPoint(x: p.x + cos(bearing) * 20 * sign, y: p.y + sin(bearing) * 20 * sign)
        }

        path.move(to: CGPoint(x: (a.x + d.x) / 2, y: (a.y + d.y) / 2))
        path.addArc(tangent1End: a, tangent2End: along(a, outerStart, 1), radius: oc)
        path.addArc(center: .zero, radius: outer, startAngle: pathAngle(outerStart) + oc / outer,
                    endAngle: pathAngle(outerEnd) - oc / outer, clockwise: false)
        path.addArc(tangent1End: b, tangent2End: c, radius: oc)
        path.addArc(tangent1End: c, tangent2End: along(c, innerEnd, -1), radius: ic)
        path.addArc(center: .zero, radius: inner, startAngle: pathAngle(innerEnd) - ic / inner,
                    endAngle: pathAngle(innerStart) + ic / inner, clockwise: true)
        path.addArc(tangent1End: d, tangent2End: a, radius: ic)
        path.closeSubpath()
        return path
    }

    /// Petal under an offset, or nil for the hole, outside the ring and gutters.
    func hit(_ offset: CGPoint, count: Int) -> Int? {
        let radius = hypot(offset.x, offset.y)
        guard count > 0, radius >= inner, radius <= outer else { return nil }
        guard count > 1 else { return 0 }
        let step = 2 * .pi / CGFloat(count)
        var heading = atan2(offset.x, -offset.y)
        if heading < 0 { heading += 2 * .pi }
        let index = Int((heading + step / 2) / step) % count
        var delta = heading - bearing(index, of: count)
        if delta > .pi { delta -= 2 * .pi }
        // Distance from the point to the nearest sector edge must clear half a gutter.
        let edgeDistance = radius * sin(step / 2 - abs(delta))
        return edgeDistance >= gap / 2 ? index : nil
    }
}
