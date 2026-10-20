import AppKit
import SwiftUI

/// Copy Text results: the recognized text is copied as soon as it is ready,
/// shown for review, and can be saved beside the original as a .txt file.
@MainActor
final class TextResultsModel: ObservableObject {
    struct Entry: Sendable { let url: URL; let text: String; let error: String? }
    let files: [URL]
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = true
    @Published var status: String?

    init(files: [URL]) { self.files = files }

    /// All text; files are separated by their names when there are several.
    var combined: String {
        let found = entries.filter { !$0.text.isEmpty }
        if found.count == 1 { return found[0].text }
        return found.map { "— \($0.url.lastPathComponent) —\n\($0.text)" }.joined(separator: "\n\n")
    }

    func finish(_ results: [Entry]) {
        entries = results
        loading = false
        guard !combined.isEmpty else { status = "No text found"; return }
        copy()
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        status = "Copied \(combined.count.formatted()) characters"
    }

    func save() {
        do {
            for entry in entries where !entry.text.isEmpty {
                let folder = entry.url.deletingLastPathComponent()
                let stem = entry.url.deletingPathExtension().lastPathComponent
                var target = folder.appendingPathComponent("\(stem) (text).txt"), n = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(stem) (text) \(n).txt"); n += 1
                }
                try entry.text.write(to: target, atomically: true, encoding: .utf8)
            }
            status = "Saved beside the original"
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}

struct TextResultsView: View {
    @ObservedObject var model: TextResultsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder").font(.system(size: 18, weight: .medium)).foregroundStyle(Color(nsColor: Brand.accent))
                Text("Grab Text").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let status = model.status { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.files.count == 1 ? "Recognizing text…" : "Recognizing text in \(model.files.count) files…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    Text(model.combined.isEmpty ? errors : model.combined)
                        .font(.system(size: 12)).textSelection(.enabled)
                        .foregroundStyle(model.combined.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .accessibilityLabel("Recognized text")
                HStack {
                    Spacer()
                    Button("Save as Text File") { model.save() }.disabled(model.combined.isEmpty)
                    Button("Copy") { model.copy() }.keyboardShortcut("c").disabled(model.combined.isEmpty)
                }
                .controlSize(.small)
            }
        }
        .padding(16).frame(width: 420)
    }

    private var errors: String {
        let messages = model.entries.compactMap { e in e.error.map { "\(e.url.lastPathComponent): \($0)" } }
        return messages.isEmpty ? "No text was found." : messages.joined(separator: "\n")
    }
}

enum TextResultsWindow {
    @MainActor static func make(model: TextResultsModel) -> NSWindow {
        let host = NSHostingView(rootView: TextResultsView(model: model))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380), styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = host
        window.title = "Grab Text"
        return window
    }
}
