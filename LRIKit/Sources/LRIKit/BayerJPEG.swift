import Foundation
import CoreGraphics
import ImageIO

public enum BayerJPEGError: Error, CustomStringConvertible {
    case notBayerJpeg
    case decodeFailed(plane: Int)
    case unexpectedPlaneSize(plane: Int, expected: (Int, Int), got: (Int, Int))

    public var description: String {
        switch self {
        case .notBayerJpeg: "capture is not in RAW_BAYER_JPEG format"
        case .decodeFailed(let plane): "failed to decode JPEG plane \(plane)"
        case .unexpectedPlaneSize(let plane, let expected, let got):
            "plane \(plane) is \(got.0)x\(got.1), expected \(expected.0)x\(expected.1)"
        }
    }
}

/// One 8-bit-per-pixel decoded JPEG plane from a `RAW_BAYER_JPEG` capture.
public struct BayerJPEGPlane: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, 8-bit grayscale samples.
    public let samples: [UInt8]
}

extension RawImage {
    /// Decodes a `RAW_BAYER_JPEG` capture's embedded JPEG plane(s).
    ///
    /// For a monochrome capture (`format == 1`) this returns a single
    /// full-resolution plane. For a color capture (`format == 0`) it returns
    /// four half-resolution planes, one per Bayer position -- **the mapping
    /// from plane index to CFA position is not established** (the community
    /// reverse-engineering of this format explicitly hasn't confirmed it;
    /// see `Sources/CLRIProto/ATTRIBUTION.md` / `bayer_jpeg.md`). Use
    /// `assembleColorMosaic(planes:)` for a best-guess assembly you can
    /// swap the ordering of once we can verify against a known reference
    /// image.
    public func decodedBayerPlanes() throws -> [BayerJPEGPlane] {
        guard case .bayerJpeg(_, let format, let jpeg0, let jpeg1, let jpeg2, let jpeg3) = data else {
            throw BayerJPEGError.notBayerJpeg
        }

        if format == 1 {
            return [try Self.decode(jpeg: jpeg0, plane: 0)]
        }
        return [
            try Self.decode(jpeg: jpeg0, plane: 0),
            try Self.decode(jpeg: jpeg1, plane: 1),
            try Self.decode(jpeg: jpeg2, plane: 2),
            try Self.decode(jpeg: jpeg3, plane: 3),
        ]
    }

    private static func decode(jpeg: Data, plane: Int) throws -> BayerJPEGPlane {
        guard
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BayerJPEGError.decodeFailed(plane: plane)
        }

        let width = cgImage.width
        let height = cgImage.height
        var samples = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &samples,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw BayerJPEGError.decodeFailed(plane: plane)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return BayerJPEGPlane(width: width, height: height, samples: samples)
    }

    /// Assembles four half-resolution Bayer planes into a full-resolution,
    /// 10-bit-promoted (`<< 2`) Bayer mosaic, using the row-major 2x2-tile
    /// guess documented in `bayer_jpeg.md` (plane 0 = top-left, 1 = top-right,
    /// 2 = bottom-left, 3 = bottom-right of each 2x2 CFA tile). This is a
    /// **best guess, not a confirmed mapping** -- verify against a shot with
    /// a known color target before trusting color output from this path.
    /// Full 10-bit reconstruction by summing the (currently discarded) low
    /// bits across planes is not implemented -- see `bayer_jpeg.md`.
    public static func assembleColorMosaic(planes: [BayerJPEGPlane]) throws -> [UInt16] {
        guard planes.count == 4 else {
            throw BayerJPEGError.unexpectedPlaneSize(plane: -1, expected: (0, 0), got: (planes.count, 0))
        }
        let half = planes[0]
        for (i, plane) in planes.enumerated() where plane.width != half.width || plane.height != half.height {
            throw BayerJPEGError.unexpectedPlaneSize(plane: i, expected: (half.width, half.height), got: (plane.width, plane.height))
        }

        let fullWidth = half.width * 2
        let fullHeight = half.height * 2
        var mosaic = [UInt16](repeating: 0, count: fullWidth * fullHeight)

        for y in 0..<half.height {
            for x in 0..<half.width {
                let srcIndex = y * half.width + x
                let tileOrigin = (y * 2) * fullWidth + (x * 2)
                mosaic[tileOrigin] = UInt16(planes[0].samples[srcIndex]) << 2
                mosaic[tileOrigin + 1] = UInt16(planes[1].samples[srcIndex]) << 2
                mosaic[tileOrigin + fullWidth] = UInt16(planes[2].samples[srcIndex]) << 2
                mosaic[tileOrigin + fullWidth + 1] = UInt16(planes[3].samples[srcIndex]) << 2
            }
        }

        return mosaic
    }
}
