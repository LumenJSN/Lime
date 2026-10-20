import AppKit
import SwiftUI
import AVFoundation
import AVKit

/// Makes any container previewable by AVFoundation through a small proxy.
enum MediaProxy {
    private static let cache = ProxyCache()

    static func playable(_ url: URL) async -> URL {
        if let cached = cache.get(url) { return cached }
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true, ((try? await asset.load(.duration))?.seconds ?? 0) > 0 { return url }
        let audioOnly = FormatCatalog.audio.contains(FormatCatalog.format(of: url) ?? "")
        let proxy = FileManager.default.temporaryDirectory.appendingPathComponent("LimePreview-" + UUID().uuidString + (audioOnly ? ".m4a" : ".mp4"))
        var args = ["-i", url.path]
        if audioOnly { args += ["-vn", "-c:a", "aac_at", "-b:a", "128k"] }
        else { args += ["-map", "0:v:0", "-map", "0:a?", "-vf", "scale=-2:'min(540,ih)'", "-c:v", "h264_videotoolbox", "-b:v", "1500k", "-pix_fmt", "yuv420p", "-c:a", "aac_at", "-b:a", "128k"] }
        do { try await FFmpeg.run(args + [proxy.path], duration: 0, context: nil) } catch { return url }
        cache.set(url, proxy)
        return proxy
    }

    private final class ProxyCache: @unchecked Sendable {
        private var map: [URL: URL] = [:]
        private let lock = NSLock()
        func get(_ url: URL) -> URL? { lock.lock(); defer { lock.unlock() }; return map[url] }
        func set(_ url: URL, _ proxy: URL) { lock.lock(); map[url] = proxy; lock.unlock() }
    }
}

/// AVPlayer wrapper with range playback and a published playhead.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published var duration: Double = 0
    @Published var time: Double = 0
    @Published var playing = false
    @Published var naturalSize = CGSize(width: 16, height: 9)
    @Published var loading = true
    private var observer: Any?
    private var rangeEnd: Double?
    var rate: Float = 1

    func load(_ url: URL) async {
        loading = true
        let playable = await MediaProxy.playable(url)
        let item = AVPlayerItem(url: playable)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        let asset = item.asset
        duration = (try? await asset.load(.duration))?.seconds ?? 0
        if duration.isNaN { duration = 0 }
        if duration == 0 { duration = (try? await FFmpeg.probe(url).duration) ?? 0 }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let applied = size.applying(transform)
            naturalSize = CGSize(width: abs(applied.width), height: abs(applied.height))
        }
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.time = t.seconds
                    if let end = self.rangeEnd, t.seconds >= end { self.pause() }
                }
            }
        }
        loading = false
    }

    func seek(_ seconds: Double, exact: Bool = true) {
        let t = CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: exact ? .zero : .positiveInfinity, toleranceAfter: exact ? .zero : .positiveInfinity)
        time = t.seconds
    }

    func toggle() { playing ? pause() : play() }
    func play(from start: Double? = nil, to end: Double? = nil) {
        if let start { seek(start) }
        rangeEnd = end
        if time >= duration - 0.05 { seek(start ?? 0) }
        player.rate = rate
        playing = true
    }
    func pause() { player.pause(); playing = false; rangeEnd = nil }
    func step(frames: Int, fps: Double = 30) { pause(); seek(time + Double(frames) / fps) }
    func pan(_ options: ToolChoices) { player.volume = Float(min(1, (options.leftGain + options.rightGain) / 2)) }
}

/// `EmbeddedVideoPlayerView` without transport controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

/// Peaks decoded through ffmpeg, so every audio format has a waveform.
enum WaveformData {
    private static let cache = NSCache<NSString, NSArray>()

    static func load(_ url: URL, buckets: Int = 600, channels: Int = 1) async -> [[Float]] {
        let key = "\(url.path)#\(buckets)#\(channels)" as NSString
        if let cached = cache.object(forKey: key) as? [[Float]] { return cached }
        guard let tool = try? BundledTool.url("ffmpeg"),
              let result = try? await ProcessRunner.run(tool, ["-v", "error", "-i", url.path, "-vn", "-ac", String(channels), "-ar", "4000", "-f", "s16le", "-"]) else { return [] }
        let samples: [Int16] = result.stdout.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let frames = samples.count / channels
        guard frames > 0 else { return [] }
        var peaks = Array(repeating: [Float](repeating: 0, count: buckets), count: channels)
        for frame in 0..<frames {
            let bucket = min(buckets - 1, frame * buckets / frames)
            for c in 0..<channels {
                let value = Float(abs(Int(samples[frame * channels + c]))) / 32768
                if value > peaks[c][bucket] { peaks[c][bucket] = value }
            }
        }
        cache.setObject(peaks as NSArray, forKey: key)
        return peaks
    }
}

/// `AudioWaveformOverview`.
struct WaveSummary: View {
    let url: URL
    var channels = 1
    var tint: Color = Color.primary.opacity(0.45)
    var mirrored = true
    @State private var peaks: [[Float]] = []
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 4) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { _, channel in
                    WaveformShape(peaks: channel, mirrored: mirrored).fill(tint)
                }
                if peaks.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: url) { peaks = await WaveformData.load(url, buckets: 500, channels: channels) }
    }
}

struct WaveformShape: Shape {
    let peaks: [Float]
    var mirrored = true
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty else { return path }
        let barWidth = rect.width / CGFloat(peaks.count)
        for (i, peak) in peaks.enumerated() {
            let h = max(1, CGFloat(peak) * rect.height * (mirrored ? 1 : 1))
            let x = rect.minX + CGFloat(i) * barWidth
            let y = mirrored ? rect.midY - h / 2 : rect.maxY - h
            path.addRect(CGRect(x: x, y: y, width: max(0.8, barWidth * 0.75), height: h))
        }
        return path
    }
}

/// `VideoThumbnailTimeline`: evenly spaced frames behind the timeline.
struct FilmStrip: View {
    let url: URL
    @State private var images: [NSImage] = []
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width / CGFloat(max(1, images.count)), height: geo.size.height).clipped()
                }
            }
            .task(id: url) {
                let playable = await MediaProxy.playable(url)
                let asset = AVURLAsset(url: playable)
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                guard duration > 0 else { return }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 160, height: 160)
                let count = max(4, Int(geo.size.width / 60))
                var result: [NSImage] = []
                for i in 0..<count {
                    let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                    if let (cg, _) = try? await generator.image(at: t) { result.append(NSImage(cgImage: cg, size: .zero)) }
                }
                images = result
            }
        }
        .accessibilityLabel("Clip filmstrip")
    }
}

/// Timeline with a scrubbable playhead and optional range handles.
struct TimelineTrack<Background: View>: View {
    @ObservedObject var player: PreviewPlayer
    var range: Binding<ClosedRange<Double>>? = nil
    var markers: [Double] = []
    var bands: [(ClosedRange<Double>, Color)] = []
    @ViewBuilder var background: Background
    var onTapTime: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(0.001, player.duration)
            let x: (Double) -> CGFloat = { CGFloat($0 / d) * w }
            let t: (CGFloat) -> Double = { min(d, max(0, Double($0 / w) * d)) }
            ZStack(alignment: .topLeading) {
                background.frame(width: w, height: geo.size.height).clipShape(RoundedRectangle(cornerRadius: 6))
                ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                    Rectangle().fill(band.1).frame(width: max(2, x(band.0.upperBound) - x(band.0.lowerBound)), height: geo.size.height).offset(x: x(band.0.lowerBound))
                }
                if let range {
                    // Dim outside the kept range.
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: x(range.wrappedValue.lowerBound), height: geo.size.height)
                    Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, w - x(range.wrappedValue.upperBound)), height: geo.size.height).offset(x: x(range.wrappedValue.upperBound))
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: Brand.accent), lineWidth: 3)
                        .frame(width: max(8, x(range.wrappedValue.upperBound) - x(range.wrappedValue.lowerBound)), height: geo.size.height)
                        .offset(x: x(range.wrappedValue.lowerBound)).allowsHitTesting(false)
                    handle(at: x(range.wrappedValue.lowerBound), height: geo.size.height, leading: true)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            let new = min(t(g.location.x), range.wrappedValue.upperBound - 0.05)
                            range.wrappedValue = max(0, new)...range.wrappedValue.upperBound
                            player.seek(range.wrappedValue.lowerBound)
                        })
                        .focusable()
                        .onMoveCommand { nudge(range, leading: true, direction: $0, d: d) }
                        .accessibilityLabel("Start: drag to adjust, or use arrow keys for 0.01-second steps")
                    handle(at: x(range.wrappedValue.upperBound), height: geo.size.height, leading: false)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            let new = max(t(g.location.x), range.wrappedValue.lowerBound + 0.05)
                            range.wrappedValue = range.wrappedValue.lowerBound...min(d, new)
                            player.seek(range.wrappedValue.upperBound)
                        })
                        .focusable()
                        .onMoveCommand { nudge(range, leading: false, direction: $0, d: d) }
                        .accessibilityLabel("End: drag to adjust, or use arrow keys for 0.01-second steps")
                }
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    Rectangle().fill(Color.white).frame(width: 2, height: geo.size.height).offset(x: x(m) - 1)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                }
                Rectangle().fill(Color.white).frame(width: 2, height: geo.size.height + 8).offset(x: x(player.time) - 1, y: -4)
                    .shadow(color: .black.opacity(0.6), radius: 1.5).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                player.pause(); player.seek(t(g.location.x), exact: false)
            }.onEnded { g in
                player.seek(t(g.location.x)); onTapTime?(t(g.location.x))
            })
        }
        .accessibilityLabel("Filmstrip. Drag to seek.")
    }

    /// Arrow keys move the focused trim handle by 0.01 seconds.
    private func nudge(_ range: Binding<ClosedRange<Double>>, leading: Bool, direction: MoveCommandDirection, d: Double) {
        let step: Double
        switch direction { case .left, .down: step = -0.01; case .right, .up: step = 0.01; @unknown default: return }
        let r = range.wrappedValue
        if leading {
            range.wrappedValue = min(max(0, r.lowerBound + step), r.upperBound - 0.05)...r.upperBound
            player.seek(range.wrappedValue.lowerBound)
        } else {
            range.wrappedValue = r.lowerBound...max(min(d, r.upperBound + step), r.lowerBound + 0.05)
            player.seek(range.wrappedValue.upperBound)
        }
    }

    private func handle(at x: CGFloat, height: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Brand.accent))
            .frame(width: 12, height: height + 6)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: height * 0.4))
            .offset(x: leading ? x - 12 : x, y: -3)
            .help("Pull the edges to cut")
    }
}

/// `ToolPlaybackBar`: play/pause, frame steps and time readout.
struct TransportBar: View {
    @ObservedObject var player: PreviewPlayer
    var playRange: ClosedRange<Double>? = nil
    var body: some View {
        HStack(spacing: 10) {
            Button { player.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }.buttonStyle(.plain).help("Previous frame")
            Button {
                if player.playing { player.pause() }
                else if let r = playRange { player.play(from: r.lowerBound, to: r.upperBound) } else { player.play() }
            } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).help(player.playing ? "Pause (Space)" : "Play (Space)")
            Button { player.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }.buttonStyle(.plain).help("Next frame")
            Text("\(TimeFormat.string(player.time)) / \(TimeFormat.string(player.duration))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 13))
    }
}

enum TimeFormat {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        return String(format: "%d:%05.2f", minutes, s - Double(minutes * 60))
    }
}

/// Seconds field used for start/end entry.
struct SecondsField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(title, value: $value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).frame(width: 74)
                .accessibilityLabel("\(title) (s)")
        }
    }
}
