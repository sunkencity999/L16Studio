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
    /// The finishing look (Auto, Vivid, ...), applied after the raw
    /// development; `nil` leaves the developed image as it is.
    public var look: LookSettings?

    public init(exposure: Float = 0, temperature: Float? = nil, tint: Float? = nil, look: LookSettings? = nil) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.look = look
    }

    /// The raw-development part only. Fusion merges developed frames and
    /// applies the look once, to the merged result.
    public var withoutLook: RenderAdjustments {
        var copy = self
        copy.look = nil
        return copy
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
    /// The shot's capture details, written into exported files.
    public let metadata: ShotMetadata

    /// As-shot white balance as Core Image derived it from the DNG
    /// (colour modules only).
    public private(set) var asShotTemperature: Float?
    public private(set) var asShotTint: Float?

    private let lock = NSLock()
    /// The exact as-shot neutral, kept so "no override" restores it
    /// precisely (temperature/tint round-trips are lossy).
    private var asShotChromaticity: CGPoint = .zero
    private let filter: CIRAWFilter
    /// Measured once from the as-shot rendering, so that later exposure or
    /// white-balance changes aren't quietly undone by the Auto correction.
    private var measurement: LookMeasurement?
    private let blackLevel: Float
    private let baselineEV: Float

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public let isMonochrome: Bool

    public init(image: RawImage, file: LRIFile) throws {
        self.image = image
        self.orientation = file.metadata.orientation ?? .normal
        self.metadata = file.metadata
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
        // Measure first (it renders with as-shot settings), then develop.
        var look: (LookSettings, LookMeasurement)?
        if let settings = adjustments.look {
            look = (settings, settings.usesAutoCorrection ? measureLocked() : .identity)
        }
        apply(adjustments)

        guard var output = filter.outputImage else { throw ImageRendererError.rawFilterProducedNoOutput }
        if let (settings, measured) = look {
            output = LookRenderer.apply(settings, measurement: measured, to: output, scale: CGFloat(filter.scaleFactor))
        }
        guard let cg = Self.context.createCGImage(
            output, from: output.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        ) else {
            throw ImageRendererError.renderFailed
        }
        return cg
    }

    /// The Auto measurement for this lens (computed on first use).
    public func lookMeasurement() -> LookMeasurement {
        lock.lock()
        defer { lock.unlock() }
        return measureLocked()
    }

    /// Call with `lock` held. Measures the as-shot rendering at whatever
    /// size the filter is currently set to, shrunk with a plain transform.
    /// (Changing the filter's own scale here and restoring it afterwards
    /// left later full-size renders at the small size.)
    private func measureLocked() -> LookMeasurement {
        if let measurement { return measurement }
        apply(.none)
        var result = LookMeasurement.identity
        if let developed = filter.outputImage, developed.extent.width > 0 {
            let scale = min(1, 360 / max(developed.extent.width, developed.extent.height))
            let small = developed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = Self.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) {
                result = LookMeasurement.analyse(cg)
            }
        }
        measurement = result
        return result
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
    ///
    /// `sceneLinear` leaves out Core Image's tone curve ("boost"), so the
    /// values stay proportional to the light that reached the sensor. That
    /// is what a raw file should hold: the program that opens it applies
    /// its own curve.
    func renderLinear(_ adjustments: RenderAdjustments = .none, sceneLinear: Bool = false) throws -> RGBPlanes {
        lock.lock()
        defer { lock.unlock() }
        filter.isDraftModeEnabled = false
        filter.scaleFactor = 1
        apply(adjustments)
        let boost = filter.boostAmount
        if sceneLinear { filter.boostAmount = 0 }
        defer { filter.boostAmount = boost }
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
        var properties = metadata.imageProperties(
            focalLength35: image.camera.focalLength, lens: image.camera, exposure: image.exposure)
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
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
