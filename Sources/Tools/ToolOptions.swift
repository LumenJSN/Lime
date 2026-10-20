import Foundation
import CoreGraphics

/// Options gathered by tool windows.
struct ToolChoices: Sendable {
    enum SizeGoal: String, CaseIterable, Sendable { case preset, fileSize, percentage }
    enum SquashLevel: String, CaseIterable, Codable, Sendable { case gentle, hard }
    enum ResizeCap: String, CaseIterable, Codable, Sendable {
        case original, px2560, px1920, px1280
        var title: String { switch self { case .original: "Full size"; case .px2560: "2560 px longest edge"; case .px1920: "1920 px longest edge"; case .px1280: "1280 px longest edge" } }
        var maxDimension: Int? { switch self { case .original: nil; case .px2560: 2560; case .px1920: 1920; case .px1280: 1280 } }
    }
    enum VideoFitPass: String, CaseIterable, Sendable { case accurate, fast }
    enum ClipExport: String, CaseIterable, Sendable { case clips, merged }
    enum WaveLook: String, CaseIterable, Sendable { case waveform, poster }
    enum WaveCanvas: String, CaseIterable, Sendable { case landscape, portrait, square }
    enum MaskFill: String, CaseIterable, Sendable { case solid, blur }

    // Compress
    var sizeGoal: SizeGoal = .percentage
    var squashLevel: SquashLevel = .gentle
    var goalSizeText = ""
    var goalSizeUnit = "MB"
    var shrinkPercent = 50.0
    var resizeCap: ResizeCap = .original
    var videoFitPass: VideoFitPass = .accurate

    // Metadata
    var tagEntries: [TagEntry] = []
    var wipeAllTags = true

    // Photo tools
    var photoTweaks = PhotoTweaks()
    var annotations: [Markup] = []
    var backdropSettings = BackdropSettings()
    var cropRect: CGRect? = nil              // normalised 0…1, top-left origin
    var cropPixelSize: CGSize? = nil         // exact output size, optional
    var applyCropToAll = true
    var redactions: [MaskBox] = []
    var maskFill: MaskFill = .solid
    var maskColor: RGBColor = .black
    var collage = MosaicSettings()

    // Audio and video
    var levelTargetLUFS = -16.0
    var levelRangeLU = 11.0
    var levelPeakDB = -1.5
    var cutStart = 0.0
    var cutLength = 0.0
    var dropSilentEnds = false
    var silenceFloorDB = -50.0
    var tempoFactor = 1.0
    var frameGrabTimes: [Double] = []
    var sliceTimes: [Double] = []
    var droppedSlices: Set<Int> = []
    var clipExport: ClipExport = .clips
    var waveLook: WaveLook = .waveform
    var posterURL: URL? = nil
    var waveCanvas: WaveCanvas = .landscape
    var outputChannels = 2
    var leftGain = 1.0
    var rightGain = 1.0
    var censorSpans: [ClosedRange<Double>] = []
    var orderedFiles: [URL]? = nil

    // PDF
    var pageSequence: [Int] = []
    var pageTurns: [Int: Int] = [:]
    var matchPageWidths = false

    func targetBytes(original: Int) -> Int? {
        switch sizeGoal {
        case .preset: return nil
        case .percentage:
            let reduction = min(99, max(1, shrinkPercent)) / 100
            return Int(Double(original) * (1 - reduction))
        case .fileSize:
            let normalized = goalSizeText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            guard let value = Double(normalized), value > 0 else { return nil }
            let unit: Double = ["KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000][goalSizeUnit] ?? 1_000_000
            return Int(value * unit)
        }
    }
}

struct TagEntry: Identifiable, Hashable, Sendable {
    let id: String          // storage key, e.g. "exif.Model" or "ffmpeg.artist"
    let label: String
    var value: String
    var editable = true
    var removed = false
    /// Section heading in the editor ("File", "Exif", "Document", "File tags").
    var group = ""
    var removable = true
}

struct PhotoTweaks: Equatable, Sendable {
    var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0
    var whites = 0.0, blacks = 0.0, temperature = 0.0, tint = 0.0, saturation = 0.0, vibrance = 0.0
    var gamma = 0.0, clarity = 0.0, texture = 0.0, sharpness = 0.0, dehaze = 0.0
    var fade = 0.0, vignette = 0.0, grain = 0.0, noiseReduction = 0.0, blur = 0.0
    /// Hue rotation in degrees.
    var hue = 0.0

    /// Slider sections of the Adjust Photo window.
    static let groups: [(String, [(String, WritableKeyPath<PhotoTweaks, Double>, ClosedRange<Double>)])] = [
        ("Light", [("Exposure", \.exposure, -100...100), ("Brightness", \.brightness, -100...100), ("Contrast", \.contrast, -100...100),
                   ("Highlights", \.highlights, -100...100), ("Shadows", \.shadows, -100...100), ("Whites", \.whites, -100...100),
                   ("Blacks", \.blacks, -100...100), ("Gamma", \.gamma, -100...100)]),
        ("Color", [("Temperature", \.temperature, -100...100), ("Tint", \.tint, -100...100), ("Saturation", \.saturation, -100...100),
                   ("Vibrance", \.vibrance, -100...100), ("Hue", \.hue, -180...180)]),
        ("Detail", [("Clarity", \.clarity, -100...100), ("Texture", \.texture, -100...100), ("Sharpness", \.sharpness, 0...100),
                    ("Noise Reduction", \.noiseReduction, 0...100), ("Blur", \.blur, 0...100)]),
        ("Effects", [("Dehaze", \.dehaze, -100...100), ("Fade", \.fade, 0...100), ("Vignette", \.vignette, -100...100), ("Grain", \.grain, 0...100)]),
    ]
    /// Readout beside each slider: "0.00 EV", "+12", "-30°".
    static func display(_ name: String, _ value: Double) -> String {
        switch name {
        case "Exposure": return String(format: "%.2f EV", value / 50)
        case "Hue": return "\(Int(value.rounded()))°"
        default: let v = Int(value.rounded()); return v > 0 ? "+\(v)" : v == 0 ? "+0" : "\(v)"
        }
    }
    var isIdentity: Bool { self == PhotoTweaks() }
}

struct RGBColor: Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let lime = RGBColor(r: 0.361, g: 0.722, b: 0.051)
    static let black = RGBColor(r: 0, g: 0, b: 0)
    static let white = RGBColor(r: 1, g: 1, b: 1)
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32) { r = Double((hex >> 16) & 255) / 255; g = Double((hex >> 8) & 255) / 255; b = Double(hex & 255) / 255 }
}

struct Markup: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case arrow, line, rectangle, ellipse, text, draw, highlight, number, magnifier, image }
    let id: UUID
    var kind: Kind
    /// Points in image pixel space (top-left origin).
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 1
    var color: RGBColor = .lime
    var lineWidth: CGFloat = 6
    var fontSize: CGFloat = 36
    var zoom: CGFloat = 2
    /// Picture placed by the Image tool.
    var imageURL: URL? = nil
    init(kind: Kind, start: CGPoint, end: CGPoint) { id = UUID(); self.kind = kind; self.start = start; self.end = end }
    var bounds: CGRect {
        if kind == .text {
            let lines = CGFloat(max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count))
            return CGRect(x: min(start.x, end.x), y: start.y, width: max(40, abs(end.x - start.x)), height: fontSize * 1.25 * lines)
        }
        let all = [start, end] + points
        let xs = all.map(\.x), ys = all.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

struct BackdropSettings: Equatable, Sendable {
    enum Background: Hashable, Sendable { case preset(String), color(RGBColor), image(URL) }
    /// Output ratios offered by the Backdrop window.
    enum CanvasShape: String, CaseIterable, Sendable {
        case automatic, square, wide, portrait
        var label: String { switch self { case .automatic: "Auto"; case .square: "1:1"; case .wide: "16:9"; case .portrait: "4:5" } }
        var ratio: CGFloat? { switch self { case .automatic: nil; case .square: 1; case .wide: 16.0 / 9; case .portrait: 4.0 / 5 } }
    }
    var background: Background = .preset("limeade")
    var canvasShape: CanvasShape = .automatic
    /// Pixels around the photo, its corner radius and shadow blur.
    var padding = 120.0
    var cornerRadius = 20.0
    var shadowRadius = 30.0
}

struct MaskBox: Identifiable, Hashable, Sendable {
    var id: UUID
    var rect: CGRect               // normalised 0…1, top-left origin
    var start: Double = 0          // video seconds
    var end: Double = .infinity
    init(id: UUID = UUID(), rect: CGRect, start: Double = 0, end: Double = .infinity) { self.id = id; self.rect = rect; self.start = start; self.end = end }
}

struct MosaicSettings: Equatable, Sendable {
    enum Style: String, CaseIterable, Sendable {
        case grid, horizontal, vertical, featured
        var label: String { rawValue.capitalized }
    }
    enum Canvas: String, CaseIterable, Sendable {
        case square, landscape, wide, portrait, tall
        var label: String {
            switch self { case .square: "Square · 1:1"; case .landscape: "Classic 4:3"; case .wide: "Wide · 16:9"; case .portrait: "Portrait · 3:4"; case .tall: "Tall · 9:16" }
        }
        var ratio: CGFloat { switch self { case .square: 1; case .landscape: 4.0 / 3; case .wide: 16.0 / 9; case .portrait: 3.0 / 4; case .tall: 9.0 / 16 } }
    }
    static let widths = [1024, 2048, 3072, 4096]
    var style: Style = .grid
    var columns = 2
    var canvas: Canvas = .square
    var width = 2048
    var fillCells = true
    /// Gap and corner radius as a share of the canvas width.
    var spacing = 0.02
    var cornerRadius = 0.0
    var background: RGBColor = .white
}
