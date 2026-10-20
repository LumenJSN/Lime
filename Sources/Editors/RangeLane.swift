import AppKit
import SwiftUI

/// `BleepTrack` / `RedactionTrack`: time ranges on one lane. Drag empty
/// space to add, drag a clip to move it, drag either edge to change its
/// duration. Delete removes the selected clip.
struct RangeLane: View {
    @Binding var ranges: [ClosedRange<Double>]
    @Binding var selected: Int?
    let duration: Double
    var emptyText = "Drag to mark"
    var allowsAdding = true
    var onSelect: (Double) -> Void = { _ in }

    private enum Grab { case move, leading, trailing }
    @State private var drawing: ClosedRange<Double>?
    @State private var grab: (index: Int, part: Grab, origin: ClosedRange<Double>)?
    private static let minimumLength = 0.05
    private static let edgeWidth: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let d = max(0.001, duration)
            let x: (Double) -> CGFloat = { CGFloat(min($0, d) / d) * geo.size.width }
            let t: (CGFloat) -> Double = { min(d, max(0, Double($0 / geo.size.width) * d)) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06))
                if ranges.isEmpty && drawing == nil {
                    Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                    clip(width: max(4, x(range.upperBound) - x(range.lowerBound)), height: geo.size.height, active: selected == index)
                        .offset(x: x(range.lowerBound))
                }
                if let drawing {
                    RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Brand.accent).opacity(0.5))
                        .frame(width: max(4, x(drawing.upperBound) - x(drawing.lowerBound)), height: max(4, geo.size.height - 6))
                        .offset(x: x(drawing.lowerBound))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if grab == nil, drawing == nil { begin(at: g.startLocation.x, x: x) }
                if let grab { adjust(grab, delta: t(g.location.x) - t(g.startLocation.x), d: d) }
                else if allowsAdding, abs(g.location.x - g.startLocation.x) > 3 {
                    let a = t(g.startLocation.x), b = t(g.location.x)
                    drawing = min(a, b)...max(a, b)
                }
            }.onEnded { g in
                if grab == nil, drawing == nil, abs(g.location.x - g.startLocation.x) <= 3 { selected = nil; onSelect(t(g.location.x)) }
                if let r = drawing, r.upperBound - r.lowerBound > Self.minimumLength { ranges.append(r); selected = ranges.count - 1 }
                drawing = nil; grab = nil
            })
        }
    }

    private func clip(width: CGFloat, height: CGFloat, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Brand.accent).opacity(active ? 1 : 0.75))
            .frame(width: width, height: max(4, height - 6))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(active ? 0.9 : 0), lineWidth: 1.5))
            .overlay(alignment: .leading) { edgeMark }
            .overlay(alignment: .trailing) { edgeMark }
            .allowsHitTesting(false)
    }

    private var edgeMark: some View {
        Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: 10).padding(.horizontal, 2)
    }

    /// Picks the clip under the pointer and which part of it was grabbed.
    private func begin(at location: CGFloat, x: (Double) -> CGFloat) {
        guard let index = ranges.indices.last(where: { x(ranges[$0].lowerBound) - Self.edgeWidth <= location && location <= x(ranges[$0].upperBound) + Self.edgeWidth }) else { return }
        let r = ranges[index]
        let part: Grab = abs(location - x(r.lowerBound)) <= Self.edgeWidth ? .leading : abs(location - x(r.upperBound)) <= Self.edgeWidth ? .trailing : .move
        grab = (index, part, r)
        selected = index
        onSelect(r.lowerBound)
    }

    private func adjust(_ grab: (index: Int, part: Grab, origin: ClosedRange<Double>), delta: Double, d: Double) {
        guard ranges.indices.contains(grab.index) else { return }
        let o = grab.origin
        switch grab.part {
        case .move:
            let shift = min(max(delta, -o.lowerBound), d - o.upperBound)
            ranges[grab.index] = (o.lowerBound + shift)...(o.upperBound + shift)
        case .leading:
            ranges[grab.index] = min(max(0, o.lowerBound + delta), o.upperBound - Self.minimumLength)...o.upperBound
        case .trailing:
            ranges[grab.index] = o.lowerBound...max(min(d, o.upperBound + delta), o.lowerBound + Self.minimumLength)
        }
    }

    func delete() {
        guard let s = selected, ranges.indices.contains(s) else { return }
        ranges.remove(at: s)
        selected = nil
    }
}

/// `RedactionRangeFields`: exact start and end of the selected clip.
struct SpanFields: View {
    @Binding var range: ClosedRange<Double>
    let duration: Double
    var body: some View {
        HStack(spacing: 12) {
            field("Start", value: Binding(get: { range.lowerBound }, set: { v in
                range = min(max(0, v), range.upperBound - 0.05)...range.upperBound
            }), label: "Start (s)")
            field("End", value: Binding(get: { min(range.upperBound, duration) }, set: { v in
                range = range.lowerBound...max(min(duration, v), range.lowerBound + 0.05)
            }), label: "End (s)")
        }
    }

    private func field(_ title: String, value: Binding<Double>, label: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder)
                .font(.system(size: 11)).frame(width: 64).accessibilityLabel(label)
            Text("s").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// `DeleteKeyCatcher`: Delete or Forward Delete in this window removes the
/// selection unless a text field is being edited.
struct DeleteKeyCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }
    func updateNSView(_ view: WatcherView, context: Context) { view.action = action }

    final class WatcherView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, [51, 117].contains(event.keyCode),
                      !(window.firstResponder is NSText) else { return event }
                self.action()
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension View {
    func handleDeleteKey(_ action: @escaping () -> Void) -> some View {
        background(DeleteKeyCatcher(action: action).frame(width: 0, height: 0))
    }
}
