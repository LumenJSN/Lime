import AppKit
import SwiftUI

/// `QRCodeResultsPanel`: decoded QR payloads with copy and open buttons.
struct QRResultsView: View {
    let results: [(URL, [String])]
    @State private var copied: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 18, weight: .medium)).foregroundStyle(Color(nsColor: Brand.accent))
                Text("QR Codes").font(.system(size: 14, weight: .semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.0.lastPathComponent).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            if entry.1.isEmpty {
                                Text("No codes in these files").font(.system(size: 12)).foregroundStyle(.tertiary)
                            }
                            ForEach(entry.1, id: \.self) { code in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(code).font(.system(size: 12)).textSelection(.enabled).lineLimit(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let url = URL(string: code), let scheme = url.scheme, ["http", "https", "mailto", "tel"].contains(scheme.lowercased()) {
                                        Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
                                    }
                                    Button(copied == code ? "Copied" : "Copy") {
                                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string); copied = code
                                    }
                                    .controlSize(.small)
                                    .accessibilityLabel("Copy what the code in \(entry.0.lastPathComponent) says")
                                }
                                .padding(9).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            }
                        }
                    }
                }
            }.frame(maxHeight: 360)
        }
        .padding(16).frame(width: 380)
    }
}

enum QRResultsWindow {
    @MainActor static func make(results: [(URL, [String])]) -> NSWindow {
        let host = NSHostingView(rootView: QRResultsView(results: results))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = host
        window.title = "QR Codes"
        return window
    }
}
