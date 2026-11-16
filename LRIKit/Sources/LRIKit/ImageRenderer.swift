import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ImageRendererError: Error, CustomStringConvertible {
    case unpackingUnavailable
    case rawFilterRejectedDNG
    case rawFilterProducedNoOutput
    case renderFailed
    case destinationCreationFailed
    case monoNotYetSupported

    public var description: String {
        switch self {
        case .unpackingUnavailable: "couldn't unpack this capture's raw samples"
        case .rawFilterRejectedDNG: "CIRAWFilter rejected the generated DNG"
        case .rawFilterProducedNoOutput: "CIRAWFilter produced no output image"
        case .renderFailed: "failed to render the raw filter's output to an image"
        case .destinationCreationFailed: "failed to create an image destination for export"
        case .monoNotYetSupported: "this capture's sensor type isn't supported"
        }
    }
}

/// Turns a decoded `RawImage` into a real, viewable/exportable image by
/// building a DNG (`DNGWriter`) and handing it to Apple's own `CIRAWFilter`
/// to debayer and render -- see `DNGWriter.swift` for why, and for the
/// known color-accuracy caveat that applies to everything in this file too.
public enum ImageRenderer {
    /// Shared so repeated renders in one process reuse Core Image's caches.
    private static let context = CIContext()

    /// Unpacks, builds a DNG, and renders it via `CIRAWFilter`. This is the
    /// one call the app UI needs for "show me this capture as a photo."
    ///
    /// - Parameter thumbnailScale: if provided (0...1), enables `CIRAWFilter`'s
    ///   draft mode and scales the output for a fast preview -- debayering a
    ///   full 4160x3120 capture takes real time, and a gallery grid showing
    ///   up to 16 lenses per shot shouldn't do that eagerly for every tile.
    ///   Pass `nil` for full quality (detail view, export).
    public static func render(_ image: RawImage, from file: LRIFile, thumbnailScale: Float? = nil) throws -> CGImage {
        guard let samples = try image.unpackedSamples() else {
            // BayerJPEG path: not yet wired into DNG export -- see BayerJPEG.swift's
            // documented plane-ordering uncertainty; revisit once that's confirmed.
            throw ImageRendererError.unpackingUnavailable
        }
        guard image.cfaPattern != nil || image.sensor == .ar1335Mono else {
            throw ImageRendererError.monoNotYetSupported
        }

        let blackLevel = file.metadata.sensorData.first(where: { $0.sensorType == image.sensor })?.characterization.blackLevel
        let dngData = try DNGWriter.write(
            image: image,
            samples: samples,
            blackLevel: blackLevel,
            orientation: file.metadata.orientation ?? .normal,
            neutral: image.asShotNeutral(file.metadata),
            baselineExposure: image.baselineExposure(file.metadata)
        )

        guard let filter = CIRAWFilter(imageData: dngData, identifierHint: nil) else {
            throw ImageRendererError.rawFilterRejectedDNG
        }
        if let thumbnailScale {
            filter.isDraftModeEnabled = true
            filter.scaleFactor = thumbnailScale
        }
        guard let ciImage = filter.outputImage else {
            throw ImageRendererError.rawFilterProducedNoOutput
        }
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ImageRendererError.renderFailed
        }
        return cgImage
    }

    /// Convenience for gallery/grid thumbnails: fast draft-mode render,
    /// scaled so its longest side is approximately `maxDimension` pixels.
    public static func renderThumbnail(_ image: RawImage, from file: LRIFile, maxDimension: Int = 512) throws -> CGImage {
        let scale = Float(maxDimension) / Float(max(image.width, image.height))
        return try render(image, from: file, thumbnailScale: min(1.0, max(0.05, scale)))
    }

    /// Writes the raw DNG (no rendering) -- the "give me a real RAW file"
    /// export path, editable in Lightroom/Photos/etc.
    public static func exportDNG(_ image: RawImage, from file: LRIFile, to url: URL) throws {
        guard let samples = try image.unpackedSamples() else {
            throw ImageRendererError.unpackingUnavailable
        }
        let blackLevel = file.metadata.sensorData.first(where: { $0.sensorType == image.sensor })?.characterization.blackLevel
        let dngData = try DNGWriter.write(
            image: image,
            samples: samples,
            blackLevel: blackLevel,
            orientation: file.metadata.orientation ?? .normal,
            neutral: image.asShotNeutral(file.metadata),
            baselineExposure: image.baselineExposure(file.metadata)
        )
        try dngData.write(to: url)
    }

    /// Renders and exports as JPEG. `quality` is 0...1.
    public static func exportJPEG(_ image: RawImage, from file: LRIFile, to url: URL, quality: CGFloat = 0.92) throws {
        try export(image, from: file, to: url, type: .jpeg, quality: quality)
    }

    /// Renders and exports as HEIC. `quality` is 0...1.
    public static func exportHEIC(_ image: RawImage, from file: LRIFile, to url: URL, quality: CGFloat = 0.92) throws {
        try export(image, from: file, to: url, type: .heic, quality: quality)
    }

    private static func export(_ image: RawImage, from file: LRIFile, to url: URL, type: UTType, quality: CGFloat) throws {
        let cgImage = try render(image, from: file)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageRendererError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageRendererError.destinationCreationFailed
        }
    }
}
