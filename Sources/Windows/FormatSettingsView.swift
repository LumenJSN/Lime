import SwiftUI

/// Searchable format list beside the defaults of the selected output format.
struct FormatSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var selected = "jpg"
    @State private var search = ""

    static let groups: [(String, [String])] = [
        ("Images", ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]),
        ("Documents", ["pdf", "docx", "pages", "ppt", "pptx", "txt", "md", "rtf", "rtfd", "textClipping", "html", "epub"]),
        ("Spreadsheets", ["xlsx", "xls", "ods", "csv", "tsv"]),
        ("Audio", ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]),
        ("Video", ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"]),
        ("Archives", ["zip", "tar", "gz", "rar"]),
        ("Subtitles", ["srt", "vtt"]),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 124)
            Divider().padding(.vertical, 8)
            ScrollView { FormatDetail(settings: settings, format: selected).padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 12) }
                .frame(maxWidth: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).accessibilityLabel("Output formats")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .padding(.horizontal, 5).padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredGroups, id: \.0) { group in
                        Text(group.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                            .padding(.leading, 9).padding(.top, 8).padding(.bottom, 1)
                        ForEach(group.1, id: \.self) { format in row(format) }
                    }
                }.padding(.horizontal, 5).padding(.bottom, 8)
            }
        }
    }

    private var filteredGroups: [(String, [String])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Self.groups }
        return Self.groups.compactMap { name, formats in
            let hits = formats.filter { FormatCatalog.label($0).lowercased().contains(query) }
            return hits.isEmpty ? nil : (name, hits)
        }
    }

    private func row(_ format: String) -> some View {
        Button { selected = format } label: {
            Text(FormatCatalog.label(format)).font(.system(size: 13))
                .foregroundStyle(selected == format ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected == format ? Color(nsColor: Brand.accent).opacity(0.28) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FormatCatalog.label(format))
        .accessibilityAddTraits(selected == format ? .isSelected : [])
    }
}

/// Settings for one output format.
struct FormatDetail: View {
    @ObservedObject var settings: AppSettings
    let format: String

    private var label: String { FormatCatalog.label(format) }
    private var targets: [String] { FormatCatalog.targets(for: format).map(FormatCatalog.label) }
    private var isOutput: Bool { CompatibilitySettings.outputs.contains(format) }
    private var kinds: Set<String> { Self.kinds(format) }

    static func kinds(_ format: String) -> Set<String> {
        switch format {
        case "jpg": ["quality", "metadata", "photoSquash"]
        case "png": ["metadata", "photoSquash"]
        case "webp", "heic", "avif": ["quality", "metadata"]
        case "tiff": ["metadata"]
        case "docx", "pages": ["office"]
        case "epub": ["epub"]
        case "mp3", "m4a", "ogg", "opus", "wma": ["bitrate"]
        case "wav", "aiff": ["depth"]
        case "flac", "zip", "gz": ["effort"]
        case "mp4", "mov", "mkv", "webm", "avi", "wmv": ["quality", "height", "videoSquash"]
        case "gif": ["gif", "videoSquash"]
        default: []
        }
    }

    private var description: String {
        let list = ListFormatter.localizedString(byJoining: targets)
        if targets.isEmpty { return "Lime writes this format but can't read it." }
        return isOutput ? "Input and output format. Converts to \(list)." : "Input-only format. Converts to \(list)."
    }

    private func binding<T>(_ key: WritableKeyPath<ConvertPrefs, T>) -> Binding<T> {
        Binding(get: { settings.options(for: format)[keyPath: key] }, set: {
            var o = settings.options(for: format); o[keyPath: key] = $0; settings.setOptions(o, for: format)
        })
    }

    private var conversionKinds: Set<String> { kinds.subtracting(["photoSquash", "videoSquash"]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(label) Settings").font(.system(size: 15, weight: .semibold))
            Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 9)
            if !isOutput {
                Text("Each output format keeps its own defaults. Pick one on the left.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            } else if kinds.isEmpty {
                Text("Nothing to adjust for this format.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            }
            if !conversionKinds.isEmpty {
                Text("Output Defaults").font(.system(size: 13, weight: .semibold)).padding(.top, 14).padding(.bottom, 4)
                conversionRows
                HStack { Spacer(); TintedButton(title: "Reset") { settings.resetOptions(for: format) } }
                    .padding(.top, 6)
            }
            if kinds.contains("photoSquash") { photoSquash }
            if kinds.contains("videoSquash") { videoSquash }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var conversionRows: some View {
        if conversionKinds.contains("quality") {
            row("Quality") { TintedPopup(title: "Quality", selection: binding(\.qualityPreset), options: ConvertPrefs.Quality.allCases.map { ($0, $0.title) }) }
        }
        if conversionKinds.contains("metadata") {
            Toggle("Keep tags", isOn: binding(\.keepTags)).toggleStyle(.checkbox).frame(height: 28)
        }
        if conversionKinds.contains("bitrate") {
            row("Audio bitrate") { TintedPopup(title: "Audio bitrate", selection: binding(\.encodeKbps), options: ConvertPrefs.audioBitrates.map { ($0, "\($0) kbps") }) }
        }
        if conversionKinds.contains("depth") {
            row("Audio bit depth") { TintedPopup(title: "Audio bit depth", selection: binding(\.bitDepth), options: ConvertPrefs.BitDepth.allCases.map { ($0, $0.title) }) }
        }
        if conversionKinds.contains("effort") {
            row("Strength") { TintedPopup(title: "Strength", selection: binding(\.effort), options: ConvertPrefs.Effort.allCases.map { ($0, $0.title) }) }
        }
        if conversionKinds.contains("height") {
            row("Height limit") {
                TintedPopup(title: "Height limit", selection: binding(\.maxVideoHeight), options: ConvertPrefs.videoHeights.map { ($0, $0 == 0 ? "Original" : "\($0)p") })
            }
        }
        if conversionKinds.contains("gif") {
            row("Frame rate") { TintedPopup(title: "Frame rate", selection: binding(\.gifFPS), options: ConvertPrefs.gifFrameRates.map { ($0, "\($0) fps") }) }
            row("Maximum width") { TintedPopup(title: "Maximum width", selection: binding(\.gifWidthCap), options: ConvertPrefs.gifWidths.map { ($0, "\($0) px") }) }
        }
        if conversionKinds.contains("office") {
            row("PDF layout") {
                TintedPopup(title: "PDF layout", selection: binding(\.pdfDocMode), options: [("editable", "Live text"), ("pages", "Pages as pictures")])
            }
            note(settings.options(for: format).pdfDocMode == "pages"
                 ? "Every page is kept as a crisp picture, tables and maths included. The text won't be editable."
                 : "Text flows as ordinary paragraphs, headings and tables. Scanned pages go through OCR and figures stay as pictures.")
            if format == "pages" { note("Writes a real Pages file without opening Pages.") }
        }
        if conversionKinds.contains("epub") {
            row("EPUB layout") {
                TintedPopup(title: "EPUB layout", selection: binding(\.epubMode), options: [("reflowable", "Reflow text"), ("fixed", "Pages as pictures")])
            }
            note(settings.options(for: format).epubMode == "fixed"
                 ? "Each page becomes a picture in the book. Readers can't resize, select or search the text."
                 : "Text stays live with headings and tables rebuilt. Figures and hard maths stay as pictures.")
        }
    }

    private var photoSquash: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 14)
            Text("Image Compression").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            row("Strength") {
                TintedSegments(title: "Strength", selection: $settings.photoSquashLevel, options: [(.gentle, "Balanced"), (.hard, "Strong")])
            }
            row("Image size") {
                TintedPopup(title: "Image size", selection: $settings.resizeCap, options: ToolChoices.ResizeCap.allCases.map { ($0, $0.title) })
            }
            HStack {
                Spacer()
                TintedButton(title: "Reset Compression") {
                    settings.photoSquashLevel = .gentle; settings.resizeCap = .original
                }
            }.padding(.top, 6)
        }
    }

    private var videoSquash: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 14)
            Text("Compression").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            row("Strength") {
                TintedSegments(title: "Strength", selection: $settings.videoSquashLevel, options: [(.gentle, "Balanced"), (.hard, "Strong")])
            }
            note(settings.videoSquashLevel == .gentle ? "Looks close to the source and still saves space." : "Far smaller, with quality loss you may notice.")
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) { Text(title); control(); Spacer(minLength: 0) }.frame(height: 32)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }
}
