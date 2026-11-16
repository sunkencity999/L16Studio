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
    private let filter: CIRAWFilter
    private let blackLevel: Float
    private let baselineEV: Float

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public let isMonochrome: Bool

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

        guard image.cfaPattern != nil || image.sensor == .ar1335Mono else {
            throw ImageRendererError.monoNotYetSupported
        }
        // Colour modules become a CFA DNG, the monochrome module a LinearRaw
        // DNG; both go through the same CIRAWFilter pipeline, so they share
        // its tone rendering (which matters when they are merged).
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
        isMonochrome = image.cfaPattern == nil
        if !isMonochrome {
            asShotTemperature = filter.neutralTemperature
            asShotTint = filter.neutralTint
        }
        asShotChromaticity = filter.neutralChromaticity
    }

    /// Renders with the given adjustments. `maxDimension` (longest side, in
    /// pixels) enables a fast reduced-size render for thumbnails and
    /// interactive previews; `nil` renders at full sensor resolution.
    public func render(_ adjustments: RenderAdjustments = .none, maxDimension: Int? = nil) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        if let maxDimension {
            let scale = Float(maxDimension) / Float(max(image.width, image.height))
            filter.isDraftModeEnabled = scale < 0.5
            filter.scaleFactor = min(1, max(0.02, scale))
        } else {
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1
        }
        apply(adjustments)

        guard let output = filter.outputImage else { throw ImageRendererError.rawFilterProducedNoOutput }
        guard let cg = Self.context.createCGImage(
            output, from: output.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        ) else {
            throw ImageRendererError.renderFailed
        }
        return cg
    }

    private func apply(_ adj: RenderAdjustments) {
        filter.exposure = adj.exposure
        guard !isMonochrome else { return }
        if adj.temperature == nil, adj.tint == nil {
            filter.neutralChromaticity = asShotChromaticity
        } else if let asShotTemperature, let asShotTint {
            filter.neutralTemperature = adj.temperature ?? asShotTemperature
            filter.neutralTint = adj.tint ?? asShotTint
        }
    }

    /// Full-resolution render as linear-light float planes, for fusion.
    func renderLinear(_ adjustments: RenderAdjustments = .none) throws -> RGBPlanes {
        lock.lock()
        defer { lock.unlock() }
        filter.isDraftModeEnabled = false
        filter.scaleFactor = 1
        apply(adjustments)
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
