import AppKit
import SwiftUI

/// One input × output table per category, built from `FormatCatalog`.
struct CompatibilitySettings: View {
    struct Table: Identifiable {
        let title: String, symbol: String, rows: [String], columns: [String]
        var id: String { title }
    }

    static let tables: [Table] = [
        .init(title: "Images", symbol: "photo.on.rectangle", rows: ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"],
              columns: ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]),
        .init(title: "Documents", symbol: "doc.text", rows: ["pdf", "docx", "pages", "ppt", "pptx", "txt", "md", "rtf", "rtfd", "textClipping", "epub"],
              columns: ["pdf", "docx", "pages", "pptx", "txt", "md", "html", "epub", "jpg", "png", "xlsx"]),
        .init(title: "Spreadsheets", symbol: "tablecells", rows: ["xlsx", "xls", "ods", "csv", "tsv"], columns: ["xlsx", "ods", "csv", "tsv", "pdf"]),
        .init(title: "Audio", symbol: "waveform", rows: FormatCatalog.audio, columns: FormatCatalog.audio),
        .init(title: "Video", symbol: "film", rows: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"],
              columns: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]),
        .init(title: "Archives", symbol: "archivebox", rows: ["zip", "tar", "gz", "rar"], columns: ["zip", "tar", "gz"]),
        .init(title: "Subtitles", symbol: "captions.bubble", rows: ["srt", "vtt"], columns: ["srt", "vtt", "txt"]),
    ]

    static let outputs: Set<String> = Set(FormatCatalog.allInputFormats.flatMap(FormatCatalog.targets(for:)))

    @State private var hovered: (table: String, row: String, column: String)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells").font(.system(size: 11))
            Text("What Converts to What").font(.system(size: 12))
        }.padding(.leading, 8).padding(.bottom, 8)
        ForEach(Self.tables) { table in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: table.symbol).font(.system(size: 12))
                    Text(table.title).font(.system(size: 12, weight: .semibold))
                }.padding(.leading, 6).padding(.top, 2)
                grid(table)
            }
            .padding(.horizontal, 7).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .padding(.bottom, 12)
        }
    }

    private func grid(_ table: Table) -> some View {
        let compact = table.columns.count > 9
        let font = Font.system(size: compact ? 9 : 10, weight: .semibold)
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Image(systemName: "arrow.turn.right.up").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(width: compact ? 44 : 50, height: 22).accessibilityLabel("Input to output")
                ForEach(table.columns, id: \.self) { column in
                    header(FormatCatalog.label(column), font: font, highlighted: isHovered(table, column: column))
                        .accessibilityLabel("Output \(FormatCatalog.label(column))")
                }
            }
            ForEach(table.rows, id: \.self) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    header(FormatCatalog.label(row), font: font, highlighted: isHovered(table, row: row))
                        .accessibilityLabel("Input \(FormatCatalog.label(row))")
                    ForEach(table.columns, id: \.self) { column in cell(table, row: row, column: column) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func isHovered(_ table: Table, row: String? = nil, column: String? = nil) -> Bool {
        guard let hovered, hovered.table == table.title else { return false }
        return row.map { $0 == hovered.row } ?? (column.map { $0 == hovered.column } ?? false)
    }

    private func header(_ text: String, font: Font, highlighted: Bool) -> some View {
        Text(text == "TEXTCLIPPING" ? "CLIP" : text).font(font).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(highlighted ? Color(nsColor: Brand.accent).opacity(0.22) : .clear)
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
    }

    private func cell(_ table: Table, row: String, column: String) -> some View {
        let supported = FormatCatalog.targets(for: row).contains(column)
        let a = FormatCatalog.label(row), b = FormatCatalog.label(column)
        return Group {
            if supported {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.primary.opacity(0.8))
                    .accessibilityLabel("\(a) to \(b) supported").help("\(a) converts to \(b).")
            } else {
                Text("–").font(.system(size: 9)).foregroundStyle(.quaternary).accessibilityLabel("\(a) to \(b) unavailable")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22)
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = (table.title, row, column) } else if hovered?.row == row && hovered?.column == column { hovered = nil }
        }
    }
}

/// Folders the user allowed for saving results beside the originals.
struct FolderSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Text("Folders").font(.system(size: 11.5)).padding(.leading, 10).padding(.bottom, 6)
        VStack(alignment: .leading, spacing: 10) {
            Text("Lime saves results beside the originals. Choosing a folder here allows it once, with every folder inside it. Choose your home folder to cover Desktop, Documents and Downloads in one step.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.allowedFolders.isEmpty {
                Text("Nothing granted so far.").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                VStack(spacing: 6) {
                    ForEach(settings.allowedFolders, id: \.self) { path in folderRow(path) }
                }
            }
            HStack { Spacer(); TintedButton(title: "Add Folder…", action: addFolder) }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func folderRow(_ path: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { settings.allowedFolders.removeAll { $0 == path }; FolderGrants.forget(path) } label: {
                Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \((path as NSString).lastPathComponent)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func addFolder() {
        guard let url = FolderGrants.choose(message: "Choose a folder where Lime may save results. Every folder inside it is included.") else { return }
        if !settings.allowedFolders.contains(url.path) { settings.allowedFolders.append(url.path) }
    }
}

struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Lime").font(.system(size: 17, weight: .semibold)).padding(.top, 14)
            Text(version).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 10)
            Text("Unlimited uses").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 22)
            Button("Licenses") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link).font(.system(size: 13)).padding(.top, 18)
            Spacer()
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

