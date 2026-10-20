import Foundation

/// Formats Lime reads and writes, and the conversions between them.
enum FormatCatalog {
    static let imageTargets = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]
    static let images = ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]
    static let audio = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    static let video = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
    static let subtitles = ["srt", "vtt"]
    static let documents = ["docx", "pages", "md", "rtf", "rtfd", "textClipping"]
    static let spreadsheets = ["xlsx", "xls", "ods", "csv", "tsv"]
    static let documentTargets = ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"]
    static let archives = ["zip", "tar", "gz", "rar"]
    /// Formats Lime reads but never writes.
    static let inputOnly: Set<String> = ["rar", "ppt", "xls", "rtf", "rtfd", "textClipping", "webm"]

    /// Canonical format for a file, or nil for folders and unknown files.
    static func format(of url: URL) -> String? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           url.pathExtension.lowercased() != "rtfd" { return nil }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "gz" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpeg", "jpe", "jfif": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "aif", "aifc": return "aiff"
        case "markdown", "mdown": return "md"
        case "htm", "xhtml": return "html"
        case "textclipping": return "textClipping"
        case "gzip": return "gz"
        case "text": return "txt"
        default: return ext.isEmpty ? nil : ext
        }
    }

    /// Conversion targets for one source format.
    static func targets(for source: String) -> [String] {
        var result: [String]
        if images.contains(source) { result = imageTargets }
        else if audio.contains(source) { result = audio }
        else if video.contains(source) { result = video + ["gif", "mp3"] }
        else if source == "gif" { result = video }
        else if source == "pdf" { result = ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"] }
        else if ["ppt", "pptx"].contains(source) { result = ["pdf", "jpg", "png"] }
        else if spreadsheets.contains(source) { result = spreadsheets + ["pdf"] }
        else if documents.contains(source) { result = documentTargets }
        else if source == "epub" { result = ["pdf", "docx", "pages", "txt", "md", "html"] }
        else if source == "txt" { result = ["docx", "pages", "pdf", "md", "html", "epub", "jpg", "png"] }
        else if subtitles.contains(source) { result = subtitles + ["txt"] }
        else if archives.contains(source) { result = ["zip", "tar", "gz"] }
        else { result = [] }
        return result.filter { $0 != source && !inputOnly.contains($0) }
    }

    /// Wheel label for a format.
    static func label(_ format: String) -> String { format == "gz" ? "GZIP" : format.uppercased() }

    /// Extension written for an output format (`gz` archives become `.tar.gz`).
    static func fileExtension(_ format: String) -> String { format == "gz" ? "tar.gz" : format }

    /// Stem without `.tar.gz`, `.tgz` or the final extension.
    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tgz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    enum Category: String { case image, audio, video, document, spreadsheet, slides, archive, subtitle, pdf }

    static func category(_ format: String) -> Category? {
        if audio.contains(format) { return .audio }
        if video.contains(format) || format == "gif" { return .video }
        if format == "pdf" { return .pdf }
        if ["ppt", "pptx"].contains(format) { return .slides }
        if documents.contains(format) || ["txt", "html", "epub"].contains(format) { return .document }
        if spreadsheets.contains(format) { return .spreadsheet }
        if archives.contains(format) { return .archive }
        if subtitles.contains(format) { return .subtitle }
        if images.contains(format) { return .image }
        return nil
    }

    static var allInputFormats: [String] {
        images + ["gif"] + audio + video + ["pdf", "ppt", "pptx"] + documents + ["txt", "epub"] + spreadsheets + subtitles + archives
    }
}

enum LimeTool: String, CaseIterable, Sendable {
    case compress, stripTags, adjustPhoto, markUpPhoto, addBackdrop, cropPhoto
    case levelAudio, silenceVideo, cutVideo, splitPages, arrangePages, unpackArchive
    case imagesToPDF, combinePDFs, cropClip, retimeVideo, stitchVideos, grabFrames
    case sliceVideo, waveVideo, cutAudio, remixChannels, makeMosaic, scanQR
    case maskPhoto, maskVideo, censorAudio
    // Optional tools, listed last when enabled in Settings.
    case copyText, removeBackground

    var title: String {
        switch self {
        case .compress: "SHRINK"; case .stripTags: "TAGS"; case .adjustPhoto: "ADJUST"
        case .markUpPhoto: "MARK UP"; case .addBackdrop: "BACKDROP"; case .cropPhoto: "CROP"
        case .levelAudio: "LEVEL"; case .silenceVideo: "SILENCE"; case .cutVideo: "CUT"
        case .splitPages: "PAGES"; case .arrangePages: "REORDER"; case .unpackArchive: "UNPACK"
        case .imagesToPDF: "TO PDF"; case .combinePDFs: "COMBINE"; case .cropClip: "CROP"
        case .retimeVideo: "TEMPO"; case .stitchVideos: "STITCH"; case .grabFrames: "STILLS"
        case .sliceVideo: "SLICE"; case .waveVideo: "WAVE\nVIDEO"; case .cutAudio: "CUT"
        case .remixChannels: "MONO /\nSTEREO"; case .makeMosaic: "MOSAIC"; case .scanQR: "SCAN\nCODE"
        case .maskPhoto, .maskVideo: "MASK"; case .censorAudio: "CENSOR"
        case .copyText: "GRAB TEXT"; case .removeBackground: "CUT OUT"
        }
    }
    var name: String {
        switch self {
        case .compress: "Shrink File"; case .stripTags: "Edit Tags"; case .adjustPhoto: "Adjust Photo"
        case .markUpPhoto: "Mark Up Photo"; case .addBackdrop: "Backdrop"; case .cropPhoto: "Crop Photo"
        case .levelAudio: "Level Loudness"; case .silenceVideo: "Silence Clip"; case .cutVideo: "Cut Clip"
        case .splitPages: "Pages to Files"; case .arrangePages: "Reorder Pages"; case .unpackArchive: "Unpack"
        case .imagesToPDF: "Pictures to PDF"; case .combinePDFs: "Combine PDFs"; case .cropClip: "Crop Clip"
        case .retimeVideo: "Retime Video"; case .stitchVideos: "Stitch Clips"; case .grabFrames: "Save Stills"
        case .sliceVideo: "Slice Clip"; case .waveVideo: "Waveform Video"; case .cutAudio: "Cut Audio"
        case .remixChannels: "Mono / Stereo"; case .makeMosaic: "Photo Mosaic"; case .scanQR: "Scan Codes"
        case .maskPhoto: "Mask Photo"; case .maskVideo: "Mask Clip"; case .censorAudio: "Censor Audio"
        case .copyText: "Grab Text"; case .removeBackground: "Cut Out Subject"
        }
    }
    var symbol: String {
        switch self {
        case .compress: "arrow.down.circle"; case .stripTags: "tag.slash"
        case .adjustPhoto: "dial.medium"; case .markUpPhoto: "scribble.variable"
        case .addBackdrop: "square.on.square.dashed"; case .cropPhoto, .cropClip: "crop"
        case .levelAudio: "speaker.wave.2"; case .waveVideo: "waveform.path"; case .silenceVideo: "speaker.zzz"
        case .cutVideo, .cutAudio: "timeline.selection"; case .splitPages: "doc.on.doc"
        case .arrangePages: "arrow.up.arrow.down.square"; case .unpackArchive: "shippingbox"
        case .imagesToPDF: "doc.richtext"; case .combinePDFs: "square.stack"; case .retimeVideo: "gauge.with.dots.needle.67percent"
        case .stitchVideos: "link"; case .grabFrames: "photo.stack"; case .sliceVideo: "scissors"
        case .remixChannels: "speaker.wave.2.bubble.left"; case .makeMosaic: "square.grid.3x2"
        case .scanQR: "qrcode"; case .maskPhoto, .maskVideo: "rectangle.fill.on.rectangle.fill"
        case .censorAudio: "mouth"
        case .copyText: "text.viewfinder"; case .removeBackground: "person.crop.rectangle"
        }
    }
    /// Tools that combine the whole selection into one output.
    var isAggregate: Bool { [.imagesToPDF, .combinePDFs, .stitchVideos, .makeMosaic].contains(self) }
    /// Tools that stay available for a multi-file selection.
    var allowsMultipleFiles: Bool {
        [.compress, .stripTags, .cropPhoto, .levelAudio, .silenceVideo, .splitPages, .unpackArchive,
         .imagesToPDF, .combinePDFs, .stitchVideos, .makeMosaic, .copyText, .removeBackground].contains(self)
    }
    /// Optional tools behind the Settings switch.
    var isExtra: Bool { [.copyText, .removeBackground].contains(self) }
    /// Tools that open an options window before running.
    var hasOptionsWindow: Bool { ![.silenceVideo, .splitPages, .unpackArchive, .imagesToPDF, .copyText, .removeBackground].contains(self) }

    private enum Kind: Equatable { case raster, svg, gif, audio, video, pdf, archive, other }

    private static func kind(_ format: String) -> Kind {
        switch format {
        case "jpg", "png", "webp", "heic", "tiff", "avif", "bmp": .raster
        case "svg": .svg
        case "gif": .gif
        case "zip", "tar", "gz", "rar": .archive
        case "pdf": .pdf
        default:
            FormatCatalog.audio.contains(format) ? .audio : FormatCatalog.video.contains(format) ? .video : .other
        }
    }

    /// Tools for one file: editing first, then cleanup, then shrinking.
    private static func single(_ kind: Kind) -> [LimeTool] {
        switch kind {
        case .raster: [.adjustPhoto, .cropPhoto, .markUpPhoto, .maskPhoto, .addBackdrop, .stripTags, .compress]
        case .svg: [.scanQR]
        case .gif: [.scanQR, .stripTags]
        case .audio: [.cutAudio, .levelAudio, .remixChannels, .censorAudio, .waveVideo, .stripTags, .compress]
        case .video: [.cutVideo, .sliceVideo, .cropClip, .retimeVideo, .maskVideo, .silenceVideo, .grabFrames, .stripTags, .compress]
        case .pdf: [.arrangePages, .splitPages, .scanQR, .stripTags, .compress]
        case .archive: [.unpackArchive]
        case .other: []
        }
    }

    /// Tools for a selection. One file gets its full list, several files of
    /// one kind get the batch tools, and a mix of pictures and PDFs can only
    /// be scanned for codes.
    static func tools(for formats: [String]) -> [LimeTool] {
        guard !formats.isEmpty else { return [] }
        let kinds = formats.map(kind)
        if formats.count == 1 { return single(kinds[0]) }
        let images = kinds.allSatisfy { $0 == .raster || $0 == .svg }
        if images {
            return kinds.contains(.svg) ? [.makeMosaic, .imagesToPDF] : [.cropPhoto, .makeMosaic, .imagesToPDF, .stripTags, .compress]
        }
        if kinds.allSatisfy({ $0 == kinds[0] }) {
            switch kinds[0] {
            case .audio: return [.levelAudio, .stripTags, .compress]
            case .video: return [.stitchVideos, .silenceVideo, .stripTags, .compress]
            case .pdf: return [.combinePDFs, .splitPages, .scanQR, .stripTags, .compress]
            case .archive: return [.unpackArchive]
            default: break
            }
        }
        let readable = kinds.allSatisfy { [.raster, .svg, .gif, .pdf].contains($0) }
        return readable ? [.scanQR] : []
    }

    /// Extra tools for a selection: text from images, GIFs and PDFs, and
    /// background removal for photos.
    static func extraTools(for formats: [String]) -> [LimeTool] {
        guard !formats.isEmpty else { return [] }
        let kinds = formats.map(kind)
        var result: [LimeTool] = []
        if kinds.allSatisfy({ [.raster, .gif, .pdf].contains($0) }) { result.append(.copyText) }
        if BackgroundRemoval.isAvailable, kinds.allSatisfy({ $0 == .raster }) { result.append(.removeBackground) }
        return result
    }

    static func tools(for format: String, count: Int) -> [LimeTool] {
        count < 1 ? [] : tools(for: Array(repeating: format, count: count))
    }
}

enum DropAction: String, CaseIterable, Sendable {
    case shelf, copy, move, airDrop, pathToClipboard, shellHere
    var title: String {
        switch self {
        case .shelf: "SHELF"; case .copy: "COPY TO"; case .move: "MOVE TO"
        case .airDrop: "AIRDROP"; case .pathToClipboard: "PATH"; case .shellHere: "SHELL"
        }
    }
    var symbol: String {
        switch self {
        case .shelf: "tray.full"; case .copy: "plus.square.on.square"; case .move: "arrow.right.doc.on.clipboard"
        case .airDrop: "dot.radiowaves.left.and.right"; case .pathToClipboard: "link"; case .shellHere: "apple.terminal"
        }
    }
}

enum WheelMode: String, CaseIterable, Sendable { case convert, tools, actions }

enum WheelOperation: Hashable, Sendable {
    case convert(String)
    case tool(LimeTool)
    case action(DropAction)
}

struct WheelItem: Identifiable, Hashable, Sendable {
    let operation: WheelOperation
    var id: String {
        switch operation {
        case .convert(let f): "convert:" + f
        case .tool(let t): "tool:" + t.rawValue
        case .action(let a): "action:" + a.rawValue
        }
    }
    var title: String {
        switch operation {
        case .convert(let f): FormatCatalog.label(f)
        case .tool(let t): t.title
        case .action(let a): a.title
        }
    }
    var symbol: String? {
        switch operation {
        case .convert: nil
        case .tool(let t): t.symbol
        case .action(let a): a.symbol
        }
    }
}

enum WheelCatalog {
    /// Operations shared by every selected file, in the source table order.
    static func items(for files: [URL], mode: WheelMode, extras: Bool = false) -> [WheelItem] {
        guard !files.isEmpty else { return [] }
        switch mode {
        case .actions:
            return DropAction.allCases.map { WheelItem(operation: .action($0)) }
        case .convert:
            let formats = files.map(FormatCatalog.format(of:))
            guard let first = formats.first, let firstFormat = first, formats.allSatisfy({ $0 != nil }) else { return [] }
            var shared = FormatCatalog.targets(for: firstFormat)
            for format in formats.dropFirst() {
                let allowed = Set(FormatCatalog.targets(for: format!))
                shared = shared.filter(allowed.contains)
            }
            return shared.map { WheelItem(operation: .convert($0)) }
        case .tools:
            let formats = files.map(FormatCatalog.format(of:))
            guard formats.allSatisfy({ $0 != nil }) else { return [] }
            let known = formats.compactMap { $0 }
            let tools = LimeTool.tools(for: known) + (extras ? LimeTool.extraTools(for: known) : [])
            return tools.map { WheelItem(operation: .tool($0)) }
        }
    }
}
