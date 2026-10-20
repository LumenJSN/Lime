import Foundation

struct LimeError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Per-output-format conversion defaults (Settings → Formats).
struct ConvertPrefs: Codable, Equatable, Sendable {
    enum Quality: String, Codable, CaseIterable, Sendable {
        case smaller, balanced, higher
        var title: String { switch self { case .smaller: "Smaller File"; case .balanced: "Balanced"; case .higher: "Higher Quality" } }
        var value: Double { switch self { case .smaller: 0.6; case .balanced: 0.8; case .higher: 0.92 } }
    }
    enum Effort: String, Codable, CaseIterable, Sendable {
        case faster, balanced, smallest
        var title: String { switch self { case .faster: "Faster"; case .balanced: "Balanced"; case .smallest: "Smallest File" } }
        var level: Int { switch self { case .faster: 1; case .balanced: 6; case .smallest: 9 } }
    }
    enum BitDepth: String, Codable, CaseIterable, Sendable {
        case source, int16, int24, int32, float32
        var title: String {
            switch self { case .source: "Match source"; case .int16: "16-bit"; case .int24: "24-bit"; case .int32: "32-bit"; case .float32: "32-bit float" }
        }
    }

    var qualityPreset: Quality = .balanced
    var keepTags = true
    var encodeKbps = 256
    var bitDepth: BitDepth = .source
    var effort: Effort = .balanced
    var maxVideoHeight = 0
    var gifFPS = 15
    var gifWidthCap = 960
    var epubMode = "reflowable"
    var pdfDocMode = "editable"

    static let audioBitrates = [128, 192, 256, 320]
    static let videoHeights = [0, 2160, 1080, 720, 480]
    static let gifFrameRates = [10, 15, 24]
    static let gifWidths = [480, 960, 1280]

    /// Encoder quality from 0 to 1 for the chosen preset.
    var quality: Double {
        get { qualityPreset.value }
        set { qualityPreset = Quality.allCases.min { abs($0.value - newValue) < abs($1.value - newValue) } ?? .balanced }
    }

    /// zlib/FLAC/PNG effort from 0 to 9.
    var compressionLevel: Int {
        get { effort.level }
        set { effort = newValue <= 2 ? .faster : newValue >= 8 ? .smallest : .balanced }
    }

    /// Native defaults differ for MOV, which favours quality.
    static func defaults(for format: String) -> ConvertPrefs {
        var options = ConvertPrefs()
        if format == "mov" { options.qualityPreset = .higher }
        return options
    }

    func validated() -> ConvertPrefs {
        var copy = self
        if !Self.audioBitrates.contains(encodeKbps) { copy.encodeKbps = 256 }
        if !Self.videoHeights.contains(maxVideoHeight) { copy.maxVideoHeight = 0 }
        if !Self.gifFrameRates.contains(gifFPS) { copy.gifFPS = 15 }
        if !Self.gifWidths.contains(gifWidthCap) { copy.gifWidthCap = 960 }
        copy.epubMode = ["reflowable", "fixed"].contains(epubMode) ? epubMode : "reflowable"
        copy.pdfDocMode = ["editable", "pages"].contains(pdfDocMode) ? pdfDocMode : "editable"
        return copy
    }
}

/// A finished file or folder waiting in the private workspace.
struct StagedOutput: Sendable {
    let staged: URL
    let directory: URL
    let stem: String
    /// Extension without the dot; empty for folders.
    let fileExtension: String
}

/// Shared state for one operation: private workspace, options and progress.
final class OperationContext: @unchecked Sendable {
    let workspace: URL
    let optionsForFormat: @Sendable (String) -> ConvertPrefs
    let outputDirectory: URL?
    private let progressHandler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var outputs: [StagedOutput] = []

    init(outputDirectory: URL?, optionsForFormat: @escaping @Sendable (String) -> ConvertPrefs,
         progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lime-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = root
        self.outputDirectory = outputDirectory
        self.optionsForFormat = optionsForFormat
        progressHandler = progress
    }
    deinit { try? FileManager.default.removeItem(at: workspace) }

    private var span: ClosedRange<Double> = 0...1
    /// Share of the overall progress that the current file reports into.
    var progressSpan: ClosedRange<Double> {
        get { lock.lock(); defer { lock.unlock() }; return span }
        set { lock.lock(); span = newValue; lock.unlock() }
    }
    func progress(_ value: Double) {
        let s = progressSpan
        progressHandler(s.lowerBound + (s.upperBound - s.lowerBound) * min(1, max(0, value)))
    }

    /// A unique scratch URL inside the workspace.
    func scratch(_ ext: String = "") -> URL {
        workspace.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }
    func scratchDirectory() throws -> URL {
        let url = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Reserves a staged output that will be published beside `source`.
    func output(for source: URL, stem: String? = nil, label: String? = nil, ext: String) -> URL {
        let base = stem ?? FormatCatalog.stem(of: source)
        let name = label.map { "\(base) (\($0))" } ?? base
        let staged = scratch(ext.isEmpty ? "" : ext)
        let record = StagedOutput(staged: staged, directory: outputDirectory ?? source.deletingLastPathComponent(), stem: name, fileExtension: ext)
        lock.lock(); outputs.append(record); lock.unlock()
        return staged
    }
    func outputFolder(for source: URL, stem: String? = nil, label: String? = nil) throws -> URL {
        let url = output(for: source, stem: stem, label: label, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    var stagedOutputs: [StagedOutput] { lock.lock(); defer { lock.unlock() }; return outputs }
}

enum OutputPublisher {
    /// First free name in the Finder style: `name.ext`, then `name 2.ext`, `name 3.ext`…
    static func uniqueURL(directory: URL, stem: String, ext: String) -> URL {
        let fm = FileManager.default
        func candidate(_ n: Int) -> URL {
            let base = n == 1 ? stem : "\(stem) \(n)"
            return directory.appendingPathComponent(ext.isEmpty ? base : base + "." + ext, isDirectory: ext.isEmpty)
        }
        var n = 1
        while fm.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    /// Moves staged results next to their originals; rolls back on failure.
    static func publish(_ outputs: [StagedOutput]) throws -> [URL] {
        let fm = FileManager.default
        var published: [URL] = []
        do {
            for output in outputs {
                try Task.checkCancellation()
                guard fm.fileExists(atPath: output.staged.path) else { throw LimeError("The encoder ended but left no file behind.") }
                if output.fileExtension.isEmpty, (try? fm.contentsOfDirectory(atPath: output.staged.path))?.isEmpty == true {
                    throw LimeError("The encoder ended but left no file behind.")
                }
                let destination = uniqueURL(directory: output.directory, stem: output.stem, ext: output.fileExtension)
                try fm.moveItem(at: output.staged, to: destination)
                published.append(destination)
            }
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
        return published
    }
}

enum ProcessRunner {
    struct Result: Sendable { let stdout: Data; let stderr: String }

    /// Runs a tool, terminating it when the surrounding task is cancelled.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], directory: URL? = nil, stdoutTo file: URL? = nil,
                    environment: [String: String]? = nil, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        let errPipe = Pipe(), outPipe = Pipe()
        process.standardError = errPipe
        let collector = OutputCollector()
        if let file {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: file)
        } else {
            process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.appendOut(data)
                if let onOutput, let text = String(data: data, encoding: .utf8) { onOutput(text) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.appendErr(data) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if file == nil { collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
        if let handle = process.standardOutput as? FileHandle { try? handle.close() }
        try Task.checkCancellation()
        let stderr = collector.errString
        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LimeError(detail.isEmpty ? "The encoder stopped with an error." : String(detail.suffix(900)))
        }
        return Result(stdout: collector.out, stderr: stderr)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()
        func appendOut(_ d: Data) { lock.lock(); outData.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); errData.append(d); lock.unlock() }
        var out: Data { lock.lock(); defer { lock.unlock() }; return outData }
        var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
    }
}

enum BundledTool {
    static func url(_ name: String) throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["LIME_TOOLS_DIR"] { candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Tools/" + name)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Resources/Tools/" + name))
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw LimeError("Lime has no encoder for \(name).")
        }
        return found
    }
}
