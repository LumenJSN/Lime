import AppKit
import SwiftUI

@MainActor
final class OperationProgressModel: ObservableObject {
    enum Phase: Equatable { case running, finished, failed(String), cancelled }
    @Published var title: String
    @Published var fraction: Double = 0
    @Published var total: Int
    @Published var saved = 0
    @Published var phase: Phase = .running
    @Published var outputs: [URL] = []
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    init(title: String, total: Int) { self.title = title; self.total = total }

    var subtitle: String {
        switch phase {
        case .running: return saved == 0 && fraction < 0.02 ? "Preparing…" : "\(saved) of \(total) saved"
        case .finished: return outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) of \(outputs.count) saved"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

/// `OperationProgressPanel`: the compact card shown after a drop.
struct OperationProgressView: View {
    @ObservedObject var model: OperationProgressModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Button {
                    if model.phase == .running { model.onCancel?() } else { model.onClose?() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 16).background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(model.phase == .running ? "Cancel" : "Close")
                Text(headline).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if case .finished = model.phase {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: Brand.accent))
                } else if case .failed = model.phase {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            Text(model.subtitle)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(model.isFailure ? 4 : 1).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 25)
            if model.phase == .running || model.phase == .finished {
                ProgressBar(fraction: model.phase == .finished ? 1 : model.fraction, indeterminate: model.phase == .running && model.fraction < 0.02)
                    .frame(height: 4).padding(.leading, 25)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 290, alignment: .leading)
        .background(
            ZStack {
                VisualEffectBlur(material: .popover)
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture {
            if model.phase == .finished, !model.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(model.outputs) }
        }
    }
    private var headline: String {
        switch model.phase {
        case .failed: return "Done, with problems"
        default: return model.title
        }
    }
}

extension OperationProgressModel {
    var isFailure: Bool { if case .failed = phase { return true }; return false }
}

/// `OrangeIndeterminateProgressView` and the determinate bar.
struct ProgressBar: View {
    var fraction: Double
    var indeterminate: Bool
    @State private var phase: CGFloat = -0.4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if indeterminate {
                    Capsule().fill(Color(nsColor: Brand.accent))
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * phase)
                        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 0.65 } }
                } else {
                    Capsule().fill(LinearGradient(colors: [Color(nsColor: Brand.accent), Color(nsColor: Brand.accentDeep)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                }
            }
            .clipShape(Capsule())
        }
    }
}

/// Places progress cards near the drop point and stacks concurrent ones.
@MainActor
final class JobCardController {
    private var panels: [NSPanel] = []

    func present(_ model: OperationProgressModel, near point: NSPoint) -> NSPanel {
        let host = NSHostingView(rootView: OperationProgressView(model: model))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        var origin = NSPoint(x: point.x - host.fittingSize.width / 2, y: point.y - host.fittingSize.height - 24)
        origin.y -= CGFloat(panels.count) * (host.fittingSize.height + 8)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 8), f.maxX - host.fittingSize.width - 8)
            origin.y = min(max(origin.y, f.minY + 8), f.maxY - host.fittingSize.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        panels.append(panel)
        model.onClose = { [weak self, weak panel] in if let panel { self?.close(panel) } }
        return panel
    }

    func resize(_ panel: NSPanel) {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }

    func close(_ panel: NSPanel, after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    self?.panels.removeAll { $0 === panel }
                }
            })
        }
    }
}
