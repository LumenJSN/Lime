import AppKit
import AVFoundation
import SwiftUI

/// Video preview filling the available area, letterboxed on black.
struct VideoStage<Overlay: View>: View {
    @ObservedObject var player: PreviewPlayer
    var padding: CGFloat = 0
    @ViewBuilder var overlay: (CGRect) -> Overlay
    var body: some View {
        GeometryReader { geo in
            let fit = aspectFitRect(player.naturalSize, in: geo.size, padding: padding)
            ZStack(alignment: .topLeading) {
                Color.black
                PlayerSurface(player: player.player).frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                overlay(fit)
                if player.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension VideoStage where Overlay == EmptyView {
    init(player: PreviewPlayer, padding: CGFloat = 0) { self.player = player; self.padding = padding; self.overlay = { _ in EmptyView() } }
}

/// Frame step, play and time readout (`ToolPlaybackBar`).
struct TransportRow: View {
    @ObservedObject var player: PreviewPlayer
    var playRange: ClosedRange<Double>? = nil
    var showPlay = true
    var body: some View {
        HStack(spacing: 14) {
            Button { player.step(frames: -1) } label: { Image(systemName: "backward.frame") }.buttonStyle(.plain).help("Previous frame")
            if showPlay {
                Button {
                    if player.playing { player.pause() }
                    else if let r = playRange { player.play(from: r.lowerBound, to: r.upperBound) } else { player.play() }
                } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).help(player.playing ? "Pause" : "Play")
            }
            Button { player.step(frames: 1) } label: { Image(systemName: "forward.frame") }.buttonStyle(.plain).help("Next frame")
            Spacer()
            Text("\(TimeFormat.string(player.time)) / \(TimeFormat.string(player.duration))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

/// Scrub slider over the whole duration.
struct ScrubSlider: View {
    @ObservedObject var player: PreviewPlayer
    var body: some View {
        Slider(value: Binding(get: { player.time }, set: { player.pause(); player.seek($0, exact: false) }), in: 0...max(0.01, player.duration))
            .controlSize(.small).accessibilityLabel("Play position (s)")
    }
}

/// "Pull the edges to cut" header with the selected length.
private struct TrimHeader: View {
    let range: ClosedRange<Double>
    var body: some View {
        HStack {
            Text("Pull the edges to cut")
            Spacer()
            Text("\(TimeFormat.string(range.upperBound - range.lowerBound)) selected").monospacedDigit()
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

private struct StartEndLabels: View {
    let range: ClosedRange<Double>
    var body: some View {
        HStack {
            Text("Start \(TimeFormat.string(range.lowerBound))")
            Spacer()
            Text("End \(TimeFormat.string(range.upperBound))")
        }
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
    }
}

/// `VideoCutEditor`.
struct VideoCutEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @State private var range: ClosedRange<Double> = 0...1
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoStage(player: player)
            TrimHeader(range: range)
            TimelineTrack(player: player, range: $range) { FilmStrip(url: model.primaryFile) }.frame(height: 56).padding(.horizontal, 12)
            StartEndLabels(range: range)
            TransportRow(player: player, playRange: range)
        }
        .padding(12)
        .task { await player.load(model.primaryFile); range = 0...max(0.1, player.duration) }
        .onChange(of: range) { r in model.options.cutStart = r.lowerBound; model.options.cutLength = r.upperBound - r.lowerBound }
    }
}

/// `AudioCutEditor` with silence trimming.
struct AudioCutEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @State private var range: ClosedRange<Double> = 0...1
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrimHeader(range: range).padding(.top, 12)
            TimelineTrack(player: player, range: $range) {
                ZStack { Color.primary.opacity(0.06); ChannelTrace(url: model.primaryFile, tint: Color(nsColor: Brand.accent)).padding(.vertical, 10) }
            }
            .frame(height: 120).padding(.horizontal, 12)
            .accessibilityLabel("Audio timeline").help("Drag to seek, then play from there")
            StartEndLabels(range: range)
            Toggle("Cut quiet edges for me", isOn: $model.options.dropSilentEnds).toggleStyle(.checkbox).font(.system(size: 13))
            HStack {
                Spacer()
                EditorButton(title: player.playing ? "Stop" : "Play Marked Part", symbol: player.playing ? "stop.fill" : "play.fill") {
                    if player.playing { player.pause() } else { player.play(from: range.lowerBound, to: range.upperBound) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .task { await player.load(model.primaryFile); range = 0...max(0.1, player.duration) }
        .onChange(of: range) { r in model.options.cutStart = r.lowerBound; model.options.cutLength = r.upperBound - r.lowerBound }
    }
}

/// `VideoSpeedEditor`: preview keeps pitch through spectral time-stretch.
struct TempoEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    static let stops: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    private var index: Binding<Double> {
        Binding(get: { Double(Self.stops.firstIndex(of: model.options.tempoFactor) ?? 2) },
                set: { model.options.tempoFactor = Self.stops[min(Self.stops.count - 1, max(0, Int($0.rounded())))] })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoStage(player: player)
            HStack {
                Text("Playback speed").font(.system(size: 13))
                Spacer()
                Text(String(format: "%g×", model.options.tempoFactor)).font(.system(size: 15, weight: .medium))
            }
            Slider(value: index, in: 0...Double(Self.stops.count - 1), step: 1).accessibilityLabel("Playback speed")
            HStack {
                ForEach(Self.stops, id: \.self) { stop in
                    Text(String(format: "%g×", stop)).font(.system(size: 10, weight: stop == model.options.tempoFactor ? .semibold : .regular))
                        .foregroundStyle(stop == model.options.tempoFactor ? .primary : .secondary)
                    if stop != Self.stops.last { Spacer() }
                }
            }
            HStack {
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }.buttonStyle(.plain).help("Play")
                Spacer()
                Text("\(TimeFormat.string(player.time)) / \(TimeFormat.string(player.duration))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .task { await player.load(model.primaryFile); player.rate = Float(model.options.tempoFactor) }
        .onChange(of: model.options.tempoFactor) { s in player.rate = Float(s); if player.playing { player.player.rate = Float(s) } }
    }
}

/// `VideoSnapshotEditor`: pick frames, starting with the first one.
struct FrameGrabEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @State private var thumbs: [Double: NSImage] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoStage(player: player).accessibilityLabel("Clip at \(TimeFormat.string(player.time))")
            ScrubSlider(player: player)
            TransportRow(player: player, showPlay: false)
            Divider()
            HStack {
                Text("\(model.options.frameGrabTimes.count) selected").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                EditorButton(title: "Add Frame") { addFrame() }.keyboardShortcut("f", modifiers: [])
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.options.frameGrabTimes.sorted(), id: \.self) { t in
                        ZStack(alignment: .topTrailing) {
                            Button { player.seek(t) } label: {
                                ZStack(alignment: .bottomLeading) {
                                    Group {
                                        if let image = thumbs[t] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { Color.black }
                                    }
                                    .frame(width: 84, height: 50).clipped()
                                    Text(TimeFormat.string(t)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 4).background(Color.black.opacity(0.55)).padding(4)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Brand.accent), lineWidth: 2))
                            }
                            .buttonStyle(.plain).help("Show this still")
                            Button { model.options.frameGrabTimes.removeAll { $0 == t } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain).padding(3).help("Drop this still")
                        }
                        .task(id: t) { thumbs[t] = await frame(at: t) }
                    }
                }
            }
            .frame(height: 54)
        }
        .padding(12)
        .task {
            await player.load(model.primaryFile)
            if model.options.frameGrabTimes.isEmpty { model.options.frameGrabTimes = [0] }
        }
    }

    private func addFrame() {
        let t = (player.time * 1000).rounded() / 1000
        if !model.options.frameGrabTimes.contains(t) { model.options.frameGrabTimes.append(t) }
    }

    private func frame(at t: Double) async -> NSImage? {
        guard let asset = player.player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        guard let (cg, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// `VideoSplitEditor`: split points on a thumbnail timeline.
struct SplitVideoEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @State private var selectedClip: Int?

    private var points: [Double] { model.options.sliceTimes.sorted() }
    private var clips: [ClosedRange<Double>] {
        let bounds = [0] + points + [max(player.duration, (points.last ?? 0) + 0.01)]
        return (0..<(bounds.count - 1)).map { bounds[$0]...bounds[$0 + 1] }
    }
    private var removed: Set<Int> { model.options.droppedSlices }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoStage(player: player).accessibilityLabel("Clip at \(TimeFormat.string(player.time))")
            HStack {
                Text(model.options.sliceTimes.count == 1 ? "1 split point" : "\(model.options.sliceTimes.count) cut marks").font(.system(size: 13))
                Spacer()
                EditorButton(title: "Add Split", symbol: "scissors") { addSplit() }.keyboardShortcut("s", modifiers: [])
                if !removed.isEmpty {
                    EditorButton(title: "Restore Clips") { model.options.droppedSlices = []; sync() }.accessibilityIdentifier("sliceRestore")
                }
                if !model.options.sliceTimes.isEmpty {
                    EditorButton(title: "Clear") { model.options.sliceTimes = []; model.options.droppedSlices = []; selectedClip = nil; sync() }
                }
            }
            TimelineTrack(player: player, markers: model.options.sliceTimes, bands: bands, background: { FilmStrip(url: model.primaryFile) },
                          onTapTime: { t in selectedClip = points.isEmpty ? nil : clips.firstIndex { $0.contains(t) } })
                .frame(height: 54)
                .accessibilityLabel("Clip filmstrip")
            TransportRow(player: player)
            if !points.isEmpty {
                if removed.isEmpty {
                    note("Select a piece and hit Delete to drop it. Space previews what's left.")
                } else {
                    EditorRow(title: "Export", secondary: true) {
                        TintedSegments(title: "Export", selection: Binding(get: { model.options.clipExport }, set: { model.options.clipExport = $0 }),
                                       options: [(.merged, "One Clip"), (.clips, "Separate Clips")], compact: true)
                    }
                    note("Drop pieces you don't want, then save the rest as one clip or as separate files.")
                }
            }
        }
        .padding(12)
        .task { await player.load(model.primaryFile) }
        .handleDeleteKey { toggleSelectedClip() }
    }

    /// Removed clips are dimmed; the selected clip is outlined in orange.
    private var bands: [(ClosedRange<Double>, Color)] {
        var result = clips.enumerated().filter { removed.contains($0.offset) }.map { ($0.element, Color.black.opacity(0.62)) }
        if let s = selectedClip, clips.indices.contains(s) { result.append((clips[s], Color(nsColor: Brand.accent).opacity(0.28))) }
        return result
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func toggleSelectedClip() {
        guard let s = selectedClip, clips.indices.contains(s) else { return }
        if removed.contains(s) { model.options.droppedSlices.remove(s) }
        else if removed.count + 1 < clips.count { model.options.droppedSlices.insert(s) }
        else { NSSound.beep(); return }
        sync()
    }

    /// Removing a clip joins the rest by default.
    private func sync() { model.options.clipExport = removed.isEmpty ? .clips : .merged }

    private func addSplit() {
        let t = player.time
        guard t > 0.05, t < player.duration - 0.05, !model.options.sliceTimes.contains(where: { abs($0 - t) < 0.05 }) else { NSSound.beep(); return }
        model.options.sliceTimes.append(t)
        model.options.droppedSlices = []
        selectedClip = nil
        sync()
    }
}

/// `CropEditor` for video.
struct VideoCropEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @State private var aspect: CropAspect = .free
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoStage(player: player, padding: 14) { fit in
                CropOverlay(rect: $rect, frame: fit, lockedRatio: aspect.ratio(source: player.naturalSize), sourceSize: player.naturalSize)
            }
            EditorRow(title: "Aspect ratio") {
                TintedSegments(title: "Aspect ratio", selection: Binding(get: { aspect }, set: { a in
                    aspect = a
                    rect = a == .free ? CGRect(x: 0, y: 0, width: 1, height: 1) : a.fitted(source: player.naturalSize)
                }), options: CropAspect.allCases.map { ($0, $0.rawValue) }, compact: true)
            }
            HStack(spacing: 8) {
                Text("W").font(.system(size: 13))
                TextField("Crop width (px)", value: Binding(get: { Int(rect.width * player.naturalSize.width) / 2 * 2 }, set: { w in
                    rect.size.width = min(1 - rect.minX, max(2, CGFloat(w)) / max(1, player.naturalSize.width))
                }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 74)
                Text("H").font(.system(size: 13))
                TextField("Crop height (px)", value: Binding(get: { Int(rect.height * player.naturalSize.height) / 2 * 2 }, set: { h in
                    rect.size.height = min(1 - rect.minY, max(2, CGFloat(h)) / max(1, player.naturalSize.height))
                }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 74)
                Text("px").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ScrubSlider(player: player)
            TransportRow(player: player, showPlay: false)
        }
        .padding(12)
        .task { await player.load(model.primaryFile); model.options.cropRect = rect }
        .onChange(of: rect) { model.options.cropRect = $0 }
        .onChange(of: model.resetCount) { _ in aspect = .free; rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }
}

/// `VideoRedactionTimeline` + `RectangleRedactionEditor` for video.
struct VideoRedactionEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoStage(player: player) { fit in
                RedactionOverlay(rects: Binding(get: { model.options.redactions }, set: { new in
                    // New rectangles start at the playhead and last to the end.
                    model.options.redactions = new.map { r in
                        model.options.redactions.contains(where: { $0.id == r.id }) ? r : MaskBox(id: r.id, rect: r.rect, start: player.time, end: .infinity)
                    }
                }), selected: $selected, frame: fit, visible: { $0.start <= player.time + 0.001 && player.time <= $0.end },
                                 style: model.options.maskFill, color: model.options.maskColor)
            }
            EditorRow(title: "Style", secondary: true) {
                TintedSegments(title: "Style", selection: $model.options.maskFill, options: [(.solid, "Solid"), (.blur, "Blur")])
                    .help("Blur only smudges detail. Pick Solid for anything private.")
            }
            EditorRow(title: "Color", secondary: true) { ColorCapsule(title: "Color", color: $model.options.maskColor) }
                .opacity(model.options.maskFill == .solid ? 1 : 0.4).disabled(model.options.maskFill != .solid)
            Text("Masks").font(.system(size: 11, weight: .semibold))
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(model.options.redactions.enumerated()), id: \.element.id) { index, item in
                        lane(index: index, item: item)
                    }
                    if model.options.redactions.isEmpty {
                        HStack(spacing: 8) {
                            Text("1").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                            Text("Draw a rectangle on the video to add").font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }
            .frame(maxHeight: 70)
            HStack(spacing: 8) {
                Image(systemName: "film").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                TimelineTrack(player: player) { FilmStrip(url: model.primaryFile) }.frame(height: 34)
            }
            TransportRow(player: player)
        }
        .padding(12)
        .task { await player.load(model.primaryFile) }
    }

    /// One redaction's time range; drag the clip or its edges to set when it shows.
    private func lane(index: Int, item: MaskBox) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            RangeLane(ranges: rangeBinding(item.id), selected: Binding(get: { selected == item.id ? 0 : nil }, set: { selected = $0 == nil ? nil : item.id }),
                      duration: player.duration, emptyText: "Drag to mark") { player.seek($0) }
                .frame(height: 20)
                .accessibilityLabel("Mask \(index + 1)")
                .contextMenu {
                    Button("Mask from here") { addAtPlayhead() }
                    Button("Keep for Whole Clip") { update(item.id) { $0.start = 0; $0.end = .infinity } }
                    Divider()
                    Button("Remove Mask") { delete(item.id) }
                }
            Button { delete(item.id) } label: {
                Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Remove redaction \(index + 1)")
        }
    }

    /// The lane edits a single range; dragging empty space replaces it.
    private func rangeBinding(_ id: UUID) -> Binding<[ClosedRange<Double>]> {
        Binding(get: {
            guard let r = model.options.redactions.first(where: { $0.id == id }) else { return [] }
            return [r.start...max(r.start, min(r.end, player.duration))]
        }, set: { new in
            guard let last = new.last else { delete(id); return }
            update(id) { $0.start = last.lowerBound; $0.end = last.upperBound >= player.duration - 0.01 ? .infinity : last.upperBound }
        })
    }

    private func update(_ id: UUID, _ change: (inout MaskBox) -> Void) {
        guard let i = model.options.redactions.firstIndex(where: { $0.id == id }) else { return }
        change(&model.options.redactions[i])
    }

    private func delete(_ id: UUID) {
        model.options.redactions.removeAll { $0.id == id }
        if selected == id { selected = nil }
    }

    /// A centred rectangle that starts at the playhead and lasts to the end.
    private func addAtPlayhead() {
        let r = MaskBox(rect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), start: player.time, end: .infinity)
        model.options.redactions.append(r)
        selected = r.id
    }
}

/// `AudioRedactionEditor`: a bleep layer above the waveform.
struct BleepEditor: View {
    @ObservedObject var model: ToolEditorModel
    @StateObject private var player = PreviewPlayer()
    @StateObject private var preview = RenderedPreview()
    @State private var selected: Int?

    private var bleepFilter: String {
        let d = max(0.01, player.duration)
        let condition = model.options.censorSpans.map { "between(t,\(FFmpeg.timestamp($0.lowerBound)),\(FFmpeg.timestamp(min($0.upperBound, d))))" }.joined(separator: "+")
        guard !condition.isEmpty else { return "[0:a:0]anull[a]" }
        return "[0:a:0]volume=0:enable='\(condition)'[m];sine=frequency=1000:sample_rate=44100:duration=\(FFmpeg.timestamp(d)),volume=0.35,volume=0:enable='not(\(condition))'[b];[m][b]amix=inputs=2:duration=first:normalize=0[a]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Censored parts").font(.system(size: 13, weight: .semibold))
                Text("\(model.options.censorSpans.count)").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                Text("Censor").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                bleepLane.frame(height: 26)
            }
            HStack(spacing: 8) {
                Text("Audio").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                AudioLane(player: player, url: model.primaryFile, tint: Color(nsColor: Brand.accent)).frame(height: 70)
                    .accessibilityLabel("Sound wave. Drag to move the play position.")
            }
            HStack {
                Text(TimeFormat.string(0)); Spacer(); Text(TimeFormat.string(player.duration))
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 48)
            if let s = selected, model.options.censorSpans.indices.contains(s) {
                HStack {
                    SpanFields(range: $model.options.censorSpans[s], duration: player.duration)
                    Spacer()
                    Button { deleteSelected() } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete selected bleep")
                }
            } else {
                Text("Drag along the censor track to mark a part. Drag the part or its edges to change it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            EditorRow(title: "Preview", secondary: true) {
                HStack(spacing: 8) {
                    EditorButton(title: "Original", symbol: preview.playing == nil && player.playing ? "stop.fill" : nil) {
                        preview.stop(); player.toggle()
                    }
                    EditorButton(title: "Censored", symbol: preview.playing == "bleeps" ? "stop.fill" : "play.fill") {
                        player.pause(); preview.toggle("bleeps", source: model.primaryFile, filter: bleepFilter, complex: true)
                    }
                    .help("Play or pause (Space)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .task { await player.load(model.primaryFile) }
        .onDisappear { preview.stop() }
        .handleDeleteKey { deleteSelected() }
        .onChange(of: model.resetCount) { _ in selected = nil }
    }

    private var bleepLane: some View {
        RangeLane(ranges: $model.options.censorSpans, selected: $selected, duration: player.duration, emptyText: "Drag to censor") { player.seek($0) }
            .accessibilityLabel("Censor track")
            .contextMenu {
                Button("Censor from here") { addAtPlayhead() }
                Button("Censor Everything") { model.options.censorSpans = [0...player.duration]; selected = 0 }
                if selected != nil { Divider(); Button("Remove Censor") { deleteSelected() } }
            }
    }

    private func addAtPlayhead() {
        let start = min(player.time, max(0, player.duration - 0.05))
        model.options.censorSpans.append(start...min(player.duration, start + 0.5))
        selected = model.options.censorSpans.count - 1
    }

    private func deleteSelected() {
        guard let s = selected, model.options.censorSpans.indices.contains(s) else { return }
        model.options.censorSpans.remove(at: s); selected = nil
    }
}
