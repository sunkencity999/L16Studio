import Foundation
import CoreGraphics
import CoreImage

/// The named looks. Every one except `original` starts from the automatic
/// correction measured from the photo, so they differ in character, not in
/// whether the exposure is right. (Same set, and the same maths, as the
/// on-camera app's editor in `camera-app/.../Look.java`.)
public enum LookStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, auto, vivid, golden, crisp, film, mono

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// The taste half of a look: what the style presets set and the sliders
/// change. All zero is neutral, except `saturation` (1 = unchanged).
public struct LookSettings: Hashable, Codable, Sendable {
    public var style: LookStyle
    public var contrast: Float = 0      // -1...1
    public var highlights: Float = 0    // -1...1, positive pulls bright tones down
    public var shadows: Float = 0       // -1...1, positive lifts dark tones
    public var saturation: Float = 1    // 0 = monochrome
    public var warmth: Float = 0        // -1...1, positive is warmer
    public var fade: Float = 0          // 0...1, lifts black for a matte look
    public var split: Float = 0         // 0...1, cool shadows and warm highlights
    public var sharpen: Float = 0       // 0...1

    /// The preset for a style.
    public init(style: LookStyle) {
        self.style = style
        switch style {
        case .original:
            break
        case .auto:
            contrast = 0.12; saturation = 1.08; shadows = 0.10; sharpen = 0.35
        case .vivid:
            contrast = 0.40; saturation = 1.38; shadows = 0.18; highlights = 0.10; sharpen = 0.50
        case .golden:
            warmth = 0.55; shadows = 0.28; highlights = 0.22; contrast = 0.10; saturation = 1.12; sharpen = 0.35
        case .crisp:
            warmth = -0.30; contrast = 0.32; highlights = 0.30; shadows = 0.05; saturation = 1.04; sharpen = 0.85
        case .film:
            fade = 0.75; split = 0.8; contrast = -0.05; saturation = 0.86; warmth = 0.12; highlights = 0.20; sharpen = 0.20
        case .mono:
            saturation = 0; contrast = 0.42; shadows = -0.05; highlights = 0.12; sharpen = 0.45
        }
    }

    /// True when the settings are exactly a style's preset.
    public var isPreset: Bool { self == LookSettings(style: style) }
    /// Whether the automatic correction is part of this look.
    public var usesAutoCorrection: Bool { style != .original }
}

/// The measured half of a look: what "Auto" corrects.
public struct LookMeasurement: Hashable, Sendable {
    public var black: Float = 0     // level mapped to black, 0...1
    public var white: Float = 1     // level mapped to white
    public var gamma: Float = 1     // mid-tone correction (<1 brightens)
    public var gainR: Float = 1
    public var gainG: Float = 1
    public var gainB: Float = 1

    public static let identity = LookMeasurement()

    /// Measures a picture from a small display-encoded copy (a few hundred
    /// pixels wide is plenty).
    public static func analyse(_ image: CGImage) -> LookMeasurement {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = { () -> UnsafeMutableRawPointer? in
                  context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                  return context.data
              }()
        else { return .identity }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var histogram = [Int](repeating: 0, count: 256)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var counted = 0
        let total = w * h
        for i in 0..<total {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            let luma = (r * 54 + g * 183 + b * 19) >> 8
            histogram[luma] += 1
            // Colour cast: only nearly grey mid-tones say anything about
            // the light. The threshold is tight on purpose: with a looser
            // one, a room with pale green walls read as a green cast and
            // the "correction" turned its whites lavender.
            let hi = max(r, g, b), lo = min(r, g, b)
            if luma > 40, luma < 225, hi - lo < 26 {
                sumR += Double(r); sumG += Double(g); sumB += Double(b); counted += 1
            }
        }
        func percentile(_ fraction: Double) -> Int {
            let target = Int(Double(total) * fraction)
            var seen = 0
            for i in 0..<256 {
                seen += histogram[i]
                if seen >= target { return i }
            }
            return 255
        }

        var m = LookMeasurement()
        // Black and white points at the 0.4th / 99.6th percentiles, capped so
        // a deliberately dark or light picture isn't forced to full range.
        m.black = min(0.14, Float(percentile(0.004)) / 255)
        m.white = max(0.80, Float(percentile(0.996)) / 255)
        // Mid-tones: move the median 60% of the way to a pleasing level.
        let range = max(0.2, m.white - m.black)
        let mid = min(0.95, max(0.05, (Float(percentile(0.5)) / 255 - m.black) / range))
        let exact = logf(0.46) / logf(mid)
        m.gamma = min(1.35, max(0.65, 1 + (exact - 1) * 0.6))
        // Colour cast: nudge the neutral average half-way towards grey, at
        // most 8% per channel, and only if a good share of the picture
        // (8%) was nearly grey to begin with.
        if counted > total * 8 / 100 {
            let r = sumR / Double(counted), g = sumG / Double(counted), b = sumB / Double(counted)
            let grey = (r + g + b) / 3
            func limit(_ gain: Double) -> Float { min(1.08, max(0.92, Float(1 + (gain - 1) * 0.5))) }
            m.gainR = limit(grey / r); m.gainG = limit(grey / g); m.gainB = limit(grey / b)
        }
        return m
    }
}

/// Applies a look to an image with Core Image: a colour cube carrying the
/// per-channel tone curve and the saturation change, then sharpening.
public enum LookRenderer {
    private static let cubeSize = 48

    /// The tone curve for one channel (0 = red, 1 = green, 2 = blue),
    /// operating on display-encoded values 0...1.
    static func curve(_ x: Float, channel: Int, settings s: LookSettings, measurement m: LookMeasurement) -> Float {
        var gain: Float = channel == 0 ? m.gainR : channel == 1 ? m.gainG : m.gainB
        // Warmth trades red against blue; green stays put.
        if channel == 0 { gain *= 1 + 0.14 * s.warmth }
        if channel == 2 { gain *= 1 - 0.14 * s.warmth }

        var x = max(0, min(1, (x - m.black) / (m.white - m.black)))
        // Channel gains ease off towards white, so highlights stay neutral
        // instead of clipping one channel before the others.
        x = max(0, min(1, x * (1 + (gain - 1) * (1 - x * x))))
        x = powf(x, m.gamma)

        // Shadows and highlights: smooth bumps a third and two thirds of the
        // way up, so each leaves the other end alone.
        let shadowBump = x * (1 - x) * (1 - x) * 6.75
        let highlightBump = x * x * (1 - x) * 6.75
        x += 0.20 * s.shadows * shadowBump - 0.20 * s.highlights * highlightBump

        // Contrast: blend towards an S-curve, or towards flat grey.
        if s.contrast >= 0 {
            let sCurve = x * x * (3 - 2 * x)
            x += (sCurve - x) * s.contrast
        } else {
            x += (0.5 - x) * (-s.contrast * 0.45)
        }
        // Split toning: shadows lean cool, highlights lean warm.
        if s.split != 0, channel != 1 {
            let lean = (x - 0.5) * 0.09 * s.split
            x += channel == 0 ? lean : -lean
        }
        // Fade: lift the black point for a matte finish.
        x = s.fade * 0.11 + x * (1 - s.fade * 0.11)
        return max(0, min(1, x))
    }

    private static func cubeData(_ s: LookSettings, _ m: LookMeasurement) -> Data {
        let n = cubeSize
        // One curve table per channel, then the cube combines them with the
        // saturation change (which mixes channels, so it can't be a curve).
        var tables = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for c in 0..<3 {
            for i in 0..<n { tables[c][i] = curve(Float(i) / Float(n - 1), channel: c, settings: s, measurement: m) }
        }
        let sat = s.saturation
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        var o = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = tables[0][ri], g = tables[1][gi], b = tables[2][bi]
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    cube[o] = max(0, min(1, luma + (r - luma) * sat))
                    cube[o + 1] = max(0, min(1, luma + (g - luma) * sat))
                    cube[o + 2] = max(0, min(1, luma + (b - luma) * sat))
                    o += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Returns `image` with the look applied.
    ///
    /// - Parameters:
    ///   - measurement: from `LookMeasurement.analyse`; ignored for `.original`.
    ///   - scale: the image's size relative to full resolution (1 for full
    ///     size), so sharpening looks the same in a small preview.
    public static func apply(_ settings: LookSettings, measurement: LookMeasurement, to image: CIImage, scale: CGFloat = 1) -> CIImage {
        let m = settings.usesAutoCorrection ? measurement : .identity
        var output = image
        if settings != LookSettings(style: .original) || m != .identity {
            guard let cube = CIFilter(name: "CIColorCubeWithColorSpace"),
                  let space = CGColorSpace(name: CGColorSpace.displayP3) else { return image }
            cube.setValue(cubeSize, forKey: "inputCubeDimension")
            cube.setValue(cubeData(settings, m), forKey: "inputCubeData")
            cube.setValue(space, forKey: "inputColorSpace")
            cube.setValue(output, forKey: kCIInputImageKey)
            output = cube.outputImage ?? output
        }
        if settings.sharpen > 0.01, let sharpen = CIFilter(name: "CIUnsharpMask") {
            sharpen.setValue(output, forKey: kCIInputImageKey)
            sharpen.setValue(max(0.5, 1.6 * scale), forKey: kCIInputRadiusKey)
            sharpen.setValue(settings.sharpen * 0.9, forKey: kCIInputIntensityKey)
            output = sharpen.outputImage?.cropped(to: image.extent) ?? output
        }
        return output
    }
}

extension LookRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Applies a look to a finished image (such as a fusion result), with
    /// the Auto correction measured from that image. Returns a half-float
    /// image in linear Display P3.
    public static func apply(_ settings: LookSettings, to image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        var measurement = LookMeasurement.identity
        if settings.usesAutoCorrection {
            let scale = 360 / CGFloat(max(image.width, image.height))
            let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) {
                measurement = LookMeasurement.analyse(cg)
            }
        }
        let output = apply(settings, measurement: measurement, to: source, scale: 1)
        return context.createCGImage(
            output, from: source.extent, format: .RGBAh,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    }
}
