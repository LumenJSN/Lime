import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// `CompressionSettingsEditor`: original size, mode and the mode's control.
struct CompressEditor: View {
    @ObservedObject var model: ToolEditorModel
    private var category: FormatCatalog.Category? { FormatCatalog.category(FormatCatalog.format(of: model.primaryFile) ?? "") }
    private var totalSize: Int { model.files.reduce(0) { $0 + ImageTools.fileSize($1) } }
    private func bytes(_ value: Double) -> String { ByteCountFormatter().string(fromByteCount: Int64(value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.files.count == 1 ? model.primaryFile.lastPathComponent : "\(model.files.count) files")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.top, 14)
            Text("Original size: \(bytes(Double(totalSize)))").font(.system(size: 15, weight: .semibold)).padding(.top, 12)
                .accessibilityIdentifier("shrinkSourceSize")
            Divider().padding(.vertical, 14)
            HStack {
                Text("Mode").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                EditorPopup(title: "Mode", selection: $model.options.sizeGoal,
                            options: [(.preset, "Preset"), (.fileSize, "Exact Size"), (.percentage, "Percentage")])
            }
            Divider().padding(.vertical, 14)
            switch model.options.sizeGoal {
            case .percentage: percentage
            case .fileSize: fileSize
            case .preset: preset
            }
            if FormatCatalog.format(of: model.primaryFile) == "wav" {
                Text("WAV is saved as lossless FLAC.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.bottom, 18)
    }

    private var percentage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Reduce by").font(.system(size: 13))
                Slider(value: $model.options.shrinkPercent, in: 1...99, step: 1).accessibilityLabel("How much smaller")
                Text("\(Int(model.options.shrinkPercent))%").font(.system(size: 13)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
            Text("Expect \(bytes(Double(totalSize) * (1 - model.options.shrinkPercent / 100)))\(model.files.count > 1 ? " in total" : "") or less.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var fileSize: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Target size").font(.system(size: 13))
                Spacer()
                TextField("Size", text: $model.options.goalSizeText).textFieldStyle(.roundedBorder).frame(width: 90)
                    .accessibilityLabel("Target size")
                EditorPopup(title: "Unit", selection: $model.options.goalSizeUnit, options: [("KB", "KB"), ("MB", "MB"), ("GB", "GB")])
            }
            Text(model.files.count > 1 ? "Each file is compressed toward its own target." : "Enter a target size between 1 KB and the original size.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if category == .video {
                EditorRow(title: "Encoding") {
                    TintedSegments(title: "Encoding", selection: $model.options.videoFitPass, options: [(.accurate, "Accurate"), (.fast, "Fast")])
                }
            }
        }
    }

    private var preset: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorRow(title: "Strength") {
                TintedSegments(title: "Strength", selection: $model.options.squashLevel, options: [(.gentle, "Balanced"), (.hard, "Strong")])
            }
            Text(model.options.squashLevel == .gentle ? "Looks close to the source and still saves space." : "Far smaller, with quality loss you may notice.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if category == .image {
                EditorRow(title: "Image size") {
                    EditorPopup(title: "Image size", selection: $model.options.resizeCap,
                                options: ToolChoices.ResizeCap.allCases.map { ($0, $0.title) })
                }
            }
        }
    }
}

/// `MetadataEditorView`: every stored tag, grouped, editable where possible.
struct TagsEditor: View {
    @ObservedObject var model: ToolEditorModel
    @State private var loading = true
    @State private var search = ""

    private var groups: [(String, [Int])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = [], members: [String: [Int]] = [:]
        for (index, field) in model.options.tagEntries.enumerated() {
            guard query.isEmpty || field.label.lowercased().contains(query) || field.value.lowercased().contains(query) else { continue }
            if members[field.group] == nil { order.append(field.group) }
            members[field.group, default: []].append(index)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.files.count == 1 ? model.primaryFile.lastPathComponent : "\(model.files.count) files")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Search metadata", text: $search).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 220)
            }
            .padding(.top, 10)
            if model.files.count > 1 {
                Text("Remove All clears metadata from \(model.files.count) files. Originals are kept.").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            } else if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.options.tagEntries.isEmpty {
                Text("No metadata found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.0) { group, indices in
                            if !group.isEmpty {
                                Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 4)
                            }
                            ForEach(indices, id: \.self) { index in row(index) }
                            Divider().padding(.vertical, 6)
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
            Text("On photos this also wipes hidden camera data, so HDR and portrait depth can look different.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .task {
            model.options.wipeAllTags = model.files.count > 1
            if model.files.count == 1 { model.options.tagEntries = await MetadataTools.fields(for: model.primaryFile) }
            loading = false
        }
    }

    private func row(_ index: Int) -> some View {
        let field = model.options.tagEntries[index]
        return HStack(spacing: 10) {
            Text(field.label + ":").font(.system(size: 13)).frame(width: 180, alignment: .trailing).lineLimit(1).help(field.id)
            Group {
                if field.editable {
                    TextField(field.label, text: $model.options.tagEntries[index].value).textFieldStyle(.plain)
                } else {
                    Text(field.value).textSelection(.enabled).lineLimit(2)
                }
            }
            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .strikethrough(field.removed).opacity(field.removed ? 0.4 : 1)
            if field.removable {
                Button { model.options.tagEntries[index].removed.toggle() } label: {
                    Image(systemName: field.removed ? "arrow.uturn.backward.circle" : "minus.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help(field.removed ? "Keep \(field.label)" : "Remove \(field.label)")
            } else {
                Color.clear.frame(width: 14)
            }
        }
        .frame(minHeight: 26)
    }
}

/// `AudioNormalizationEditor`: waveform preview and loudness targets.
struct NormalizeEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.files.count == 1 ? model.primaryFile.lastPathComponent : "\(model.files.count) files").lineLimit(1)
                Spacer()
                Text(TimeFormat.string(player.duration)).monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            AudioLane(player: player, url: model.primaryFile, tint: Color(nsColor: Brand.accent)).frame(height: 190)
                .accessibilityLabel("Sound wave")
            HStack {
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).help("Play (Space)")
                Spacer()
                Text("\(TimeFormat.string(player.time)) / \(TimeFormat.string(player.duration))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            ToolSlider(title: "Target loudness", value: $model.options.levelTargetLUFS, range: -24...(-6), step: 0.5) { String(format: "%g LUFS", $0) }
            ToolSlider(title: "Loudness range", value: $model.options.levelRangeLU, range: 1...20, step: 0.5) { String(format: "%g LU", $0) }
            ToolSlider(title: "True peak limit", value: $model.options.levelPeakDB, range: -9...0, step: 0.1) { String(format: "%g dBTP", $0) }
            Text("−16 LUFS suits both voice and music. The peak cap keeps the encoded file from clipping.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.files.count > 1 {
                Text("Showing 1 of \(model.files.count). Every file gets the same settings.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .task { await player.load(model.primaryFile) }
    }
}

/// Dark lane with a waveform and a draggable playhead.
struct AudioLane: View {
    @ObservedObject var player: PreviewPlayer
    let url: URL
    var channel = 0
    var channels = 1
    var tint: Color = Color.primary.opacity(0.45)
    var playhead: Color = .white
    var body: some View {
        GeometryReader { geo in
            let d = max(0.001, player.duration)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07))
                ChannelTrace(url: url, channel: channel, channels: channels, tint: tint).padding(.vertical, 12).padding(.horizontal, 6)
                Rectangle().fill(playhead).frame(width: 2).offset(x: CGFloat(player.time / d) * geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                player.seek(min(d, max(0, Double(g.location.x / geo.size.width) * d)), exact: false)
            })
        }
    }
}

/// One channel of a file's waveform.
struct ChannelTrace: View {
    let url: URL
    var channel = 0
    var channels = 1
    var tint: Color
    @State private var peaks: [Float] = []
    var body: some View {
        WaveformShape(peaks: peaks).fill(tint)
            .task(id: url) {
                let all = await WaveformData.load(url, buckets: 180, channels: channels)
                let raw = all.indices.contains(channel) ? all[channel] : (all.first ?? [])
                // Scale to the loudest peak so quiet files still fill the lane.
                let top = max(0.0001, all.flatMap { $0 }.max() ?? 1)
                peaks = raw.map { min(1, $0 / top) }
            }
    }
}

/// Renders a short preview through ffmpeg and plays it (channel solo, output mix).
@MainActor
final class RenderedPreview: ObservableObject {
    @Published var playing: String?
    private var audio: AVAudioPlayer?
    /// `filter` is an `-af` chain, or with `complex` a graph whose output is `[a]`.
    func toggle(_ id: String, source: URL, filter: String, complex: Bool = false) {
        if playing == id { audio?.stop(); playing = nil; return }
        audio?.stop()
        playing = id
        Task {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("LimeChannel-\(UUID().uuidString).wav")
            guard let tool = try? BundledTool.url("ffmpeg"),
                  (try? await ProcessRunner.run(tool, FFmpeg.guarded(["-v", "error", "-y", "-t", "120", "-i", source.path]
                                                + (complex ? ["-filter_complex", filter, "-map", "[a]"] : ["-af", filter]) + [out.path]))) != nil,
                  let player = try? AVAudioPlayer(contentsOf: out), playing == id else { if playing == id { playing = nil }; return }
            audio = player
            player.play()
            try? await Task.sleep(nanoseconds: UInt64(player.duration * 1_000_000_000))
            if playing == id, audio === player { playing = nil }
        }
    }
    func stop() { audio?.stop(); playing = nil }
}

/// `AudioChannelsEditor`: per-channel preview, output layout and balance.
struct MonoStereoEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @StateObject private var preview = RenderedPreview()

    private var outputFilter: String {
        let l = model.options.leftGain, r = model.options.rightGain
        return model.options.outputChannels == 1
            ? String(format: "pan=mono|c0=%.3f*c0+%.3f*c1", 0.5 * l, 0.5 * r)
            : String(format: "pan=stereo|c0=%.3f*c0|c1=%.3f*c1", l, r)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Channel meter").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            channelRow("L", index: 0, name: "Left")
            channelRow("R", index: 1, name: "Right")
            Divider().padding(.vertical, 4)
            EditorRow(title: "Output") {
                TintedSegments(title: "Output channels", selection: $model.options.outputChannels, options: [(1, "Mono"), (2, "Stereo")])
            }
            InlineSlider(title: "Left level", value: $model.options.leftGain, range: 0...1, captionWidth: 90, valueWidth: 40) { "\(Int(($0 * 100).rounded()))%" }
            InlineSlider(title: "Right level", value: $model.options.rightGain, range: 0...1, captionWidth: 90, valueWidth: 40) { "\(Int(($0 * 100).rounded()))%" }
            EditorRow(title: "Preview") {
                EditorButton(title: "Play Output", symbol: preview.playing == "output" ? "stop.fill" : "play.fill") {
                    preview.toggle("output", source: model.primaryFile, filter: outputFilter)
                }
                .help("Hear the whole result with this balance")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .task { await player.load(model.primaryFile) }
        .onDisappear { preview.stop() }
    }

    private func channelRow(_ badge: String, index: Int, name: String) -> some View {
        HStack(spacing: 10) {
            Text(badge).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24).background(Circle().fill(Color.primary.opacity(0.12)))
            AudioLane(player: player, url: model.primaryFile, channel: index, channels: 2, tint: Color.primary.opacity(0.35), playhead: Color(nsColor: Brand.accent))
                .frame(height: 52).accessibilityLabel("\(name) side").help("Drag to pick the poster moment")
            Button { preview.toggle(name, source: model.primaryFile, filter: "pan=mono|c0=c\(index)") } label: {
                Image(systemName: preview.playing == name ? "stop.fill" : "play.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain).help("Play only the \(name.lowercased()) channel").accessibilityLabel("Play only the \(name.lowercased()) channel")
        }
    }
}

/// `SortedInputs`: drag to reorder; used by Join Videos and Merge PDFs.
struct SortedInputs: View {
    @ObservedObject var model: ToolEditorModel
    @State private var dragging: URL?
    private var files: [URL] { model.options.orderedFiles ?? model.files }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.tool == .stitchVideos ? "Playback order" : "Document order").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                EditorButton(title: "Sort by Name") {
                    model.options.orderedFiles = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                }
                .help("Sort by name like Finder")
            }
            .padding(.top, 12)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(files.enumerated()), id: \.element) { index, url in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
                            Thumbnail(url: url, size: 28).frame(width: 30, height: 24)
                            Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .opacity(dragging == url ? 0.5 : 1)
                        .onDrag { dragging = url; return NSItemProvider(object: url.absoluteString as NSString) }
                        .onDrop(of: [UTType.plainText], delegate: SourceDropDelegate(target: url, model: model, dragging: $dragging))
                        .accessibilityLabel("\(index + 1), \(url.lastPathComponent)").help("Drag to reorder")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct SourceDropDelegate: DropDelegate {
    let target: URL
    let model: ToolEditorModel
    @Binding var dragging: URL?
    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging, dragging != target else { return }
            var list = model.options.orderedFiles ?? model.files
            guard let from = list.firstIndex(of: dragging), let to = list.firstIndex(of: target) else { return }
            withAnimation(.easeInOut(duration: 0.15)) { list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
            model.options.orderedFiles = list
        }
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

/// `AudioVisualizerEditor`: preview of the video and its style and shape.
struct WaveVideoEditor: View {
    @ObservedObject var model: ToolEditorModel
    private var ratio: CGFloat {
        switch model.options.waveCanvas { case .landscape: 16 / 9; case .portrait: 9 / 16; case .square: 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let width = min(geo.size.width, geo.size.height * ratio)
                ZStack {
                    Color.black
                    if model.options.waveLook == .poster {
                        if let url = model.options.posterURL, let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Button("Choose Image…", action: chooseImage).buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    } else {
                        ChannelTrace(url: model.primaryFile, tint: Color(nsColor: Brand.accent)).frame(height: width / ratio * 0.7).padding(.horizontal, 8)
                    }
                }
                .frame(width: width, height: width / ratio)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .accessibilityLabel("Waveform video preview")
            }
            .padding(.top, 12)
            EditorRow(title: "Style", secondary: true) {
                EditorPopup(title: "Video look", selection: $model.options.waveLook, options: [(.waveform, "Waveform"), (.poster, "Static Image")])
            }
            EditorRow(title: "Shape", secondary: true) {
                EditorPopup(title: "Video shape", selection: $model.options.waveCanvas,
                            options: [(.landscape, "Wide 16:9"), (.portrait, "Tall 9:16"), (.square, "Square · 1:1")])
            }
            if model.options.waveLook == .poster {
                EditorRow(title: "Image", secondary: true) {
                    EditorButton(title: model.options.posterURL?.lastPathComponent ?? "Choose…", action: chooseImage)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.message = "Pick poster picture"
        if panel.runModal() == .OK { model.options.posterURL = panel.url }
    }
}
