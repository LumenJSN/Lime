import CoreImage
import Foundation
import Vision

/// Cut Out Subject: Vision's foreground instance mask
/// keeps every detected subject and writes a transparent PNG. macOS 14+.
enum BackgroundRemoval {
    static var isAvailable: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    static func run(_ source: URL, context: OperationContext) async throws {
        guard #available(macOS 14, *) else { throw LimeError("Remove Background needs macOS 14 or newer.") }
        let image = try ImageIOKit.load(source)
        context.progress(0.2)
        let cutout = try cutout(image)
        context.progress(0.8)
        let output = context.output(for: source, label: "no background", ext: "png")
        try await ImageIOKit.write(cutout, to: output, format: "png", quality: 1, pngLevel: 9)
    }

    @available(macOS 14, *)
    static func cutout(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw LimeError("No subject was found in this photo.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: space) else {
            throw LimeError("Could not create the cutout image.")
        }
        return result
    }
}
