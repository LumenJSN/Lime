import Foundation
import ImageIO

/// Animated WebP compression. ImageIO decodes the frames and the bundled
/// libwebp_anim encoder writes them back, so the animation is kept.
enum AnimatedImage {
    struct Frame { let image: CGImage; let delay: Double }

    static func frameCount(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
    }

    static func frames(_ url: URL) throws -> [Frame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LimeError("Could not read the animated image.") }
        return try (0..<CGImageSourceGetCount(source)).map { index in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw LimeError("Could not read the animated image.") }
            return Frame(image: image, delay: delay(source, index))
        }
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        let dictionaries = [kCGImagePropertyWebPDictionary, kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary]
        for key in dictionaries {
            guard let dict = props[key as String] as? [String: Any] else { continue }
            let unclamped = dict[kCGImagePropertyWebPUnclampedDelayTime as String] ?? dict[kCGImagePropertyGIFUnclampedDelayTime as String]
            let clamped = dict[kCGImagePropertyWebPDelayTime as String] ?? dict[kCGImagePropertyGIFDelayTime as String]
            if let value = (unclamped ?? clamped) as? Double, value > 0 { return value }
        }
        return 0.1
    }

    /// Writes the frames to a concat script with their durations.
    static func prepare(_ frames: [Frame], context: OperationContext) throws -> URL {
        let folder = try context.scratchDirectory()
        var script = "ffconcat version 1.0\n"
        for (index, frame) in frames.enumerated() {
            let url = folder.appendingPathComponent(String(format: "f%05d.png", index))
            try ImageIOKit.writeImageIO(frame.image, to: url, format: "png", quality: 1, metadata: [:])
            script += "file '\(url.lastPathComponent)'\nduration \(String(format: "%.3f", frame.delay))\n"
        }
        // The concat demuxer ignores the last duration unless the file repeats.
        if let last = frames.indices.last { script += String(format: "file 'f%05d.png'\n", last) }
        let list = folder.appendingPathComponent("frames.txt")
        try script.write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    static func encodeWebP(list: URL, quality: Double, to output: URL) async throws -> Int {
        try? FileManager.default.removeItem(at: output)
        try await FFmpeg.run(["-f", "concat", "-safe", "0", "-i", list.path, "-c:v", "libwebp_anim", "-lossless", "0",
                              "-quality", String(Int(quality * 100)), "-compression_level", "6", "-loop", "0",
                              "-fps_mode", "vfr", output.path], duration: 0, context: nil, trustedInputs: true)
        return ImageTools.fileSize(output)
    }

    /// Compresses an animated WebP at its original dimensions.
    static func compressWebP(_ source: URL, options: ToolChoices, target: Int?, original: Int, output: URL, context: OperationContext) async throws {
        guard options.resizeCap == .original else {
            throw LimeError("Keep the full size, otherwise the animation would be lost.")
        }
        let list = try prepare(try frames(source), context: context)
        guard let target else {
            let size = try await encodeWebP(list: list, quality: options.squashLevel == .gentle ? 0.72 : 0.48, to: output)
            if size >= original { throw LimeError("Shrinking wouldn't make this file any smaller than it already is.") }
            return
        }
        var low = 0.05, high = 0.95, best: Data?, smallest = Int.max
        for _ in 0..<6 {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let size = try await encodeWebP(list: list, quality: mid, to: output)
            smallest = min(smallest, size)
            if size <= target { low = mid; best = try Data(contentsOf: output) } else { high = mid }
        }
        guard let best else {
            try? FileManager.default.removeItem(at: output)
            let formatter = ByteCountFormatter()
            throw LimeError("Lime got it down to \(formatter.string(fromByteCount: Int64(smallest))) but no smaller.")
        }
        try best.write(to: output)
    }
}
