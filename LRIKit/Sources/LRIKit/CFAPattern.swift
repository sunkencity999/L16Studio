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
    /// The Bayer CFA pattern for this specific capture, or `nil` for a
    /// monochrome sensor. The AR1335 is BGGR-native; `bayerRedOverride`
    /// (`sensor_bayer_red_override`) shifts that per-shot -- see `LRI.md`'s
    /// note on why this varies (suspected in-camera rotation correction).
    public var cfaPattern: CFAPattern? {
        guard sensor == .ar1335 else { return nil } // ar1335Mono and .unknown have no CFA
        switch bayerRedOverride {
        case (0, 0): return CFAPattern(topLeft: .blue, topRight: .green, bottomLeft: .green, bottomRight: .red)   // BGGR
        case (1, 0): return CFAPattern(topLeft: .green, topRight: .red, bottomLeft: .blue, bottomRight: .green)   // GRBG
        case (0, 1): return CFAPattern(topLeft: .green, topRight: .blue, bottomLeft: .red, bottomRight: .green)   // GBRG
        case (1, 1): return CFAPattern(topLeft: .red, topRight: .green, bottomLeft: .green, bottomRight: .blue)   // RGGB
        default: return nil // (-1,-1) or anything unexpected: unknown override, can't determine CFA
        }
    }
}
