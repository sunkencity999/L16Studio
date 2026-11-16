import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// User adjustments applied on top of the as-shot rendering.
public struct RenderAdjustments: Sendable, Hashable, Codable {
    /// Exposure compensation in EV, on top of the module's baseline exposure.
    public var exposure: Float = 0
    /// White balance override in Kelvin; `nil` keeps the as-shot value.
    public var temperature: Float?
    /// White balance tint override; `nil` keeps the as-shot value.
    public var tint: Float?

    public init(exposure: Float = 0, temperature: Float? = nil, tint: Float? = nil) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
    }

    public static let none = RenderAdjustments()
    public var isIdentity: Bool { self == .none }
}

/// Renders one camera module of one shot, repeatedly and cheaply.
///
/// Unpacking 13 MP of packed samples and building a DNG is the expensive
/// part; this does it once and keeps the resulting `CIRAWFilter`, so moving
/// an exposure or white-balance slider only re-runs Core Image.
///
/// Colour modules go through `CIRAWFilter` (see `DNGWriter`). The monochrome
/// module has no CFA and is rendered directly as linear grey.
///
/// Thread-safety: all rendering is serialised on an internal lock, so an
/// instance can be shared between tasks.
public final class LensRenderer: @unchecked Sendable {
    public let image: RawImage
    public let orientation: Orientation

    /// As-shot white balance as Core Image derived it from the DNG
    /// (colour modules only).
    public private(set) var asShotTemperature: Float?
    public private(set) var asShotTint: Float?

    private let lock = NSLock()
    /// The exact as-shot neutral, kept so "no override" restores it
    /// precisely (temperature/tint round-trips are lossy).
    private var asShotChromaticity: CGPoint = .zero
    private let filter: CIRAWFilter?
    private let monoSamples: [UInt16]?
    private let blackLevel: Float
    private let baselineEV: Float

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public var isMonochrome: Bool { filter == nil }

    public init(image: RawImage, file: LRIFile) throws {
        self.image = image
        self.orientation = file.metadata.orientation ?? .normal
        guard let samples = try image.unpackedSamples() else {
            // BayerJPEG captures: plane ordering is still unconfirmed (see BayerJPEG.swift).
            throw ImageRendererError.unpackingUnavailable
        }
        blackLevel = file.metadata.sensorData
            .first(where: { $0.sensorType == image.sensor })?.characterization.blackLevel ?? 42
        baselineEV = image.baselineExposure(file.metadata)

        if image.cfaPattern != nil {
            let dng = try DNGWriter.write(
                image: image,
                samples: samples,
                blackLevel: blackLevel,
                orientation: orientation,
                neutral: image.asShotNeutral(file.metadata),
                baselineExposure: baselineEV
            )
            guard let filter = CIRAWFilter(imageData: dng, identifierHint: nil) else {
                throw ImageRendererError.rawFilterRejectedDNG
            }
            self.filter = filter
            self.monoSamples = nil
            asShotTemperature = filter.neutralTemperature
            asShotTint = filter.neutralTint
            asShotChromaticity = filter.neutralChromaticity
        } else if image.sensor == .ar1335Mono {
            self.filter = nil
            self.monoSamples = samples
        } else {
            throw ImageRendererError.monoNotYetSupported
        }
    }

    /// Renders with the given adjustments. `maxDimension` (longest side, in
    /// pixels) enables a fast reduced-size render for thumbnails and
    /// interactive previews; `nil` renders at full sensor resolution.
    public func render(_ adjustments: RenderAdjustments = .none, maxDimension: Int? = nil) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        if let filter {
            return try renderColor(filter, adjustments, maxDimension)
        }
        return try renderMono(adjustments, maxDimension)
    }

    private func renderColor(_ filter: CIRAWFilter, _ adj: RenderAdjustments, _ maxDimension: Int?) throws -> CGImage {
        if let maxDimension {
            let scale = Float(maxDimension) / Float(max(image.width, image.height))
            filter.isDraftModeEnabled = scale < 0.5
            filter.scaleFactor = min(1, max(0.02, scale))
        } else {
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1
        }
        filter.exposure = adj.exposure
        if adj.temperature == nil, adj.tint == nil {
            filter.neutralChromaticity = asShotChromaticity
        } else if let asShotTemperature, let asShotTint {
            filter.neutralTemperature = adj.temperature ?? asShotTemperature
            filter.neutralTint = adj.tint ?? asShotTint
        }

        guard let output = filter.outputImage else { throw ImageRendererError.rawFilterProducedNoOutput }
        guard let cg = Self.context.createCGImage(
            output, from: output.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        ) else {
            throw ImageRendererError.renderFailed
        }
        return cg
    }

    private func renderMono(_ adj: RenderAdjustments, _ maxDimension: Int?) throws -> CGImage {
        guard let samples = monoSamples else { throw ImageRendererError.renderFailed }
        let width = image.width, height = image.height
        let gain = powf(2, baselineEV + adj.exposure) / max(1, 1023 - blackLevel)
        var pixels = [UInt16](repeating: 0, count: samples.count)
        let black = blackLevel
        samples.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for i in 0..<src.count {
                    let linear = (Float(src[i]) - black) * gain
                    dst[i] = UInt16(max(0, min(1, linear)) * 65535)
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let full = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                bytesPerRow: width * 2, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ImageRendererError.renderFailed }

        // Re-draw into 8-bit display grey, applying orientation and any downscale.
        var ci = CIImage(cgImage: full)
        if orientation != .normal, let o = CGImagePropertyOrientation(rawValue: UInt32(orientation.rawValue)) {
            ci = ci.oriented(o)
        }
        if let maxDimension {
            let scale = CGFloat(maxDimension) / max(ci.extent.width, ci.extent.height)
            if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        guard let cg = Self.context.createCGImage(
            ci, from: ci.extent.integral, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        ) else {
            throw ImageRendererError.renderFailed
        }
        return cg
    }

    /// Full-resolution render as linear-light float planes, for fusion.
    func renderLinear(_ adjustments: RenderAdjustments = .none) throws -> RGBPlanes {
        lock.lock()
        defer { lock.unlock() }
        guard let filter else { throw ImageRendererError.monoNotYetSupported }
        filter.isDraftModeEnabled = false
        filter.scaleFactor = 1
        filter.exposure = adjustments.exposure
        if adjustments.temperature == nil, adjustments.tint == nil {
            filter.neutralChromaticity = asShotChromaticity
        } else if let asShotTemperature, let asShotTint {
            filter.neutralTemperature = adjustments.temperature ?? asShotTemperature
            filter.neutralTint = adjustments.tint ?? asShotTint
        }
        guard let output = filter.outputImage else { throw ImageRendererError.rawFilterProducedNoOutput }
        let extent = output.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var rgba = [Float](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw ImageRendererError.renderFailed
        }
        rgba.withUnsafeMutableBytes { buffer in
            Self.context.render(
                output, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                bounds: extent, format: .RGBAf, colorSpace: space)
        }
        return RGBPlanes(width: width, height: height, rgba: rgba)
    }

    /// Writes a rendered image to disk as JPEG or HEIC (`quality` 0...1).
    public func export(_ adjustments: RenderAdjustments = .none, to url: URL, type: UTType, quality: CGFloat = 0.92) throws {
        let cg = try render(adjustments)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageRendererError.destinationCreationFailed
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageRendererError.destinationCreationFailed }
    }
}

extension CameraID {
    /// The module's 35mm-equivalent focal length: A = 28, B = 70, C = 150.
    public var focalLength: Int {
        switch self {
        case .a1, .a2, .a3, .a4, .a5: 28
        case .b1, .b2, .b3, .b4, .b5: 70
        case .c1, .c2, .c3, .c4, .c5, .c6: 150
        }
    }

    public var label: String { String(describing: self).uppercased() }
}
