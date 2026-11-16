import Foundation

/// A 2x2 Bayer color filter array pattern, described by the color at each
/// position of the tile (row-major: top-left, top-right, bottom-left,
/// bottom-right). DNG's CFAColor enum: 0=Red, 1=Green, 2=Blue.
public enum CFAColor: UInt8, Sendable {
    case red = 0
    case green = 1
    case blue = 2
}

public struct CFAPattern: Sendable {
    public let topLeft: CFAColor
    public let topRight: CFAColor
    public let bottomLeft: CFAColor
    public let bottomRight: CFAColor

    public var dngBytes: [UInt8] {
        [topLeft.rawValue, topRight.rawValue, bottomLeft.rawValue, bottomRight.rawValue]
    }
}

extension RawImage {
    /// The Bayer CFA pattern for this capture, or `nil` for a monochrome
    /// sensor. `bayerRedOverride` (`sensor_bayer_red_override`) is the
    /// position of the red site within the 2x2 tile, as (x, y), for samples
    /// in sensor readout order (see `unpackTenBitFrame`). It differs between
    /// modules because the sensors are mounted in different orientations.
    ///
    /// Verified on a real shot (2026-11-16) against the camera's own JPEG:
    /// all nine colour modules render with correct colour under this rule,
    /// covering all four override values.
    public var cfaPattern: CFAPattern? {
        guard sensor == .ar1335 else { return nil } // ar1335Mono and .unknown have no CFA
        switch bayerRedOverride {
        case (0, 0): return CFAPattern(topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue)   // RGGB
        case (1, 0): return CFAPattern(topLeft: .green, topRight: .red, bottomLeft: .blue, bottomRight: .green)   // GRBG
        case (0, 1): return CFAPattern(topLeft: .green, topRight: .blue, bottomLeft: .red, bottomRight: .green)   // GBRG
        case (1, 1): return CFAPattern(topLeft: .blue, topRight: .green, bottomLeft: .green, bottomRight: .red)   // BGGR
        default: return nil // (-1,-1) or anything unexpected: unknown override, can't determine CFA
        }
    }
}
