import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Pixel operations shared by the photo tool previews and their outputs.
enum ImageRendering {
    static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                               .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    // MARK: Adjustments

    static func adjust(_ image: CGImage, _ a: PhotoTweaks) -> CGImage {
        guard !a.isIdentity else { return image }
        let original = CIImage(cgImage: image)
        var img = original
        let extent = original.extent
        if a.exposure != 0 { let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(a.exposure / 50); img = f.outputImage ?? img }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            let f = CIFilter.colorControls(); f.inputImage = img
            f.brightness = Float(a.brightness / 400); f.contrast = Float(1 + a.contrast / 200); f.saturation = Float(1 + a.saturation / 100)
            img = f.outputImage ?? img
        }
        if a.highlights != 0 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
            let lower: Double = max(0, -a.highlights) / 100
            let raise: Double = max(0, a.highlights) / 200
            f.highlightAmount = Float(1 - lower + raise)
            f.shadowAmount = Float(a.shadows / 100); f.radius = 8
            img = f.outputImage ?? img
        }
        if a.whites != 0 || a.blacks != 0 || a.fade != 0 || a.dehaze != 0 {
            let f = CIFilter.toneCurve(); f.inputImage = img
            let blackLift: Double = a.fade / 300 - a.blacks / 400 - a.dehaze / 600
            let white: Double = 1 + a.whites / 400
            let quarter: Double = 0.25 - a.dehaze / 1200 + a.fade / 600
            let threeQuarter: Double = 0.75 + a.dehaze / 1200
            f.point0 = CGPoint(x: 0, y: min(0.4, max(-0.2, blackLift)))
            f.point1 = CGPoint(x: 0.25, y: quarter)
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: threeQuarter)
            f.point4 = CGPoint(x: 1, y: min(1.2, max(0.6, white)))
            img = f.outputImage ?? img
        }
        if a.temperature != 0 || a.tint != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - a.temperature * 30, y: a.tint)
            img = f.outputImage ?? img
        }
        if a.hue != 0 { let f = CIFilter.hueAdjust(); f.inputImage = img; f.angle = Float(a.hue * .pi / 180); img = f.outputImage ?? img }
        if a.vibrance != 0 { let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(a.vibrance / 100); img = f.outputImage ?? img }
        if a.gamma != 0 { let f = CIFilter.gammaAdjust(); f.inputImage = img; f.power = Float(pow(2, -a.gamma / 100)); img = f.outputImage ?? img }
        if a.noiseReduction > 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = img; f.noiseLevel = Float(a.noiseReduction / 2000); f.sharpness = 0.4
            img = f.outputImage ?? img
        }
        let scale = Double(max(extent.width, extent.height)) / 1000
        if a.clarity != 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(20 * scale); f.intensity = Float(a.clarity / 150)
            img = f.outputImage ?? img
        }
        if a.texture != 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(2.5 * scale); f.intensity = Float(a.texture / 80)
            img = f.outputImage ?? img
        }
        if a.dehaze != 0 {
            let f = CIFilter.colorControls(); f.inputImage = img; f.saturation = Float(1 + a.dehaze / 400); f.contrast = Float(1 + a.dehaze / 400)
            img = f.outputImage ?? img
        }
        if a.sharpness > 0 { let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(a.sharpness / 50); f.radius = Float(1.5 * max(1, scale)); img = f.outputImage ?? img }
        if a.blur > 0 {
            let f = CIFilter.gaussianBlur(); f.inputImage = img.clampedToExtent(); f.radius = Float(a.blur / 4 * max(1, scale))
            img = (f.outputImage ?? img).cropped(to: extent)
        }
        if a.vignette != 0 {
            let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(a.vignette / 50); f.radius = Float(max(extent.width, extent.height) / 2 / 100)
            let v = CIFilter.vignetteEffect(); v.inputImage = img; v.center = CGPoint(x: extent.midX, y: extent.midY)
            v.radius = Float(max(extent.width, extent.height) * 0.45); v.intensity = Float(a.vignette / 100); v.falloff = 0.6
            img = (a.vignette > 0 ? v.outputImage : f.outputImage) ?? img
        }
        if a.grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage!.cropped(to: extent)
            let mono = CIFilter.colorControls(); mono.inputImage = noise; mono.saturation = 0; mono.brightness = -0.5; mono.contrast = 1
            let scaled = CIFilter.colorMatrix(); scaled.inputImage = mono.outputImage
            let amount = CGFloat(a.grain / 600)
            scaled.rVector = CIVector(x: amount, y: 0, z: 0, w: 0); scaled.gVector = CIVector(x: 0, y: amount, z: 0, w: 0)
            scaled.bVector = CIVector(x: 0, y: 0, z: amount, w: 0); scaled.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            let add = CIFilter.additionCompositing(); add.inputImage = scaled.outputImage; add.backgroundImage = img
            img = add.outputImage?.cropped(to: extent) ?? img
        }
        return ciContext.createCGImage(img.cropped(to: extent), from: extent) ?? image
    }

    // MARK: Crop, redact

    /// `rect` is normalised with a top-left origin.
    static func crop(_ image: CGImage, rect: CGRect, outputSize: CGSize? = nil) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixel = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard pixel.width >= 1, pixel.height >= 1, let cropped = image.cropping(to: pixel) else { throw LimeError("The crop must be at least 1 pixel wide and tall.") }
        if let size = outputSize, size.width >= 1, size.height >= 1, Int(size.width) != cropped.width || Int(size.height) != cropped.height {
            return ImageIOKit.resized(cropped, width: Int(size.width), height: Int(size.height))
        }
        return cropped
    }

    static func redact(_ image: CGImage, rects: [CGRect], style: ToolChoices.MaskFill, color: RGBColor = .black) -> CGImage {
        guard !rects.isEmpty, let context = ImageIOKit.makeContext(width: image.width, height: image.height) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        context.draw(image, in: full)
        var blurred: CGImage?
        if style == .blur {
            let input = CIImage(cgImage: image).clampedToExtent()
            let pixellate = CIFilter.pixellate(); pixellate.inputImage = input; pixellate.scale = Float(max(12, max(w, h) / 60))
            let blur = CIFilter.gaussianBlur(); blur.inputImage = pixellate.outputImage; blur.radius = Float(max(10, max(w, h) / 80))
            blurred = blur.outputImage.flatMap { ciContext.createCGImage($0, from: CIImage(cgImage: image).extent) }
        }
        for r in rects {
            let box = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
            context.saveGState()
            context.clip(to: box)
            if let blurred { context.draw(blurred, in: full) } else { context.setFillColor(color.cgColor); context.fill(box) }
            context.restoreGState()
        }
        return context.makeImage() ?? image
    }

    /// Local Vision detection of faces or text; normalised top-left rects.
    static func detect(_ kind: String, in image: CGImage) -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: image)
        var boxes: [CGRect] = []
        if kind == "faces" {
            let request = VNDetectFaceRectanglesRequest()
            try? handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox).map { $0.insetBy(dx: -$0.width * 0.12, dy: -$0.height * 0.15) }
        } else {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            try? handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox).map { $0.insetBy(dx: -0.004, dy: -$0.height * 0.15) }
        }
        return boxes.map { CGRect(x: max(0, $0.minX), y: max(0, 1 - $0.maxY), width: min(1, $0.width), height: min(1, $0.height)) }
    }

    static func qrCodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }
}

/// Backdrop gradients and flat colours.
enum FramePresets {
    static let gradients: [(String, [UInt32])] = [
        ("limeade", [0xE6F98A, 0x5CB80D]), ("pool", [0xB8F1F0, 0x2A9DD8]), ("dusk", [0x2B1E58, 0xD9668A]),
        ("peach", [0xFFE3C8, 0xF2846B]), ("fern", [0x1F4D2B, 0x7FBF6A]), ("paper", [0xFAF8F2, 0xE4DED0]),
        ("ink", [0x0F1220, 0x2E3550]), ("berry", [0x6B1E5B, 0xE0559A]), ("glacier", [0xF0F7FF, 0x9DBBE3]),
        ("ember", [0x3A0F05, 0xE8742E]), ("pistachio", [0xF4F7E1, 0xAFCB7A, 0x6F9A48]), ("haze", [0xFCE7F3, 0xD9E4FF, 0xD7F5EC]),
    ]
    static let colors: [(String, UInt32)] = [
        ("chalk", 0xF7F7F2), ("lime", 0x5CB80D), ("leaf", 0x2E7D32), ("sea", 0x1B8A9E), ("sky", 0x6EB6F5), ("indigo", 0x3949AB),
        ("plum", 0x7B3F8C), ("blush", 0xF4A7B9), ("brick", 0xB5462F), ("sand", 0xD8C3A0), ("slate", 0x5B6470), ("night", 0x111318),
    ]
}
