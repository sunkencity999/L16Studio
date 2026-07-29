import Foundation

/// Which of the L16's up to 16 camera modules a capture came from.
public enum CameraID: Int, CaseIterable, Sendable {
    case a1, a2, a3, a4, a5
    case b1, b2, b3, b4, b5
    case c1, c2, c3, c4, c5, c6

    init(_ pb: Ltpb_CameraID) {
        self = CameraID(rawValue: pb.rawValue) ?? .a1
    }
}

/// The raw sensor data's on-disk encoding within a CameraModule's Surface.
public enum DataFormat: Sendable {
    case bayerJpeg
    case packed10bpp

    init?(_ pb: Ltpb_CameraModule.Surface.FormatType) {
        switch pb {
        case .rawBayerJpeg: self = .bayerJpeg
        case .rawPacked10Bpp: self = .packed10bpp
        default: return nil // 12/14bpp and reserved formats have never been observed on the L16
        }
    }
}

/// The sensor model behind a given CameraID, from HwInfo.camera[].sensor.
public enum SensorModel: Sendable {
    case unknown
    case ar1335
    case ar1335Mono

    init(_ pb: Ltpb_SensorType) {
        switch pb {
        case .sensorAr1335: self = .ar1335
        case .sensorAr1335Mono: self = .ar1335Mono
        default: self = .unknown // AR835/IMX386 variants are defined in the protocol but never seen in the wild
        }
    }
}

public enum Whitepoint: Sendable {
    case a, d50, d65, d75, f2, f7, f11, tl84, unknown

    init(_ pb: Ltpb_ColorCalibration.IlluminantType) {
        switch pb {
        case .a: self = .a
        case .d50: self = .d50
        case .d65: self = .d65
        case .d75: self = .d75
        case .f2: self = .f2
        case .f7: self = .f7
        case .f11: self = .f11
        case .tl84: self = .tl84
        default: self = .unknown
        }
    }
}

public enum HdrMode: Sendable {
    case none, `default`, natural, surreal

    init(_ pb: Ltpb_ViewPreferences.HDRMode) {
        switch pb {
        case .none: self = .none
        case .default: self = .default
        case .natural: self = .natural
        case .surreal: self = .surreal
        }
    }
}

public enum SceneMode: Sendable {
    case portrait, landscape, sport, macro, night, none

    init(_ pb: Ltpb_ViewPreferences.SceneMode) {
        switch pb {
        case .portrait: self = .portrait
        case .landscape: self = .landscape
        case .sport: self = .sport
        case .macro: self = .macro
        case .night: self = .night
        default: self = .none
        }
    }
}

/// A 3x3 matrix, row-major, as used for color/forward matrices.
public typealias Matrix3x3 = (Float, Float, Float, Float, Float, Float, Float, Float, Float)

func matrix3x3(_ m: Ltpb_Matrix3x3F) -> Matrix3x3 {
    (m.x00, m.x01, m.x02, m.x10, m.x11, m.x12, m.x20, m.x21, m.x22)
}

/// Per-module color calibration: which matrix/ratios to apply for a given
/// reference illuminant, straight from the factory calibration data embedded
/// in the file (not computed).
public struct ColorInfo: Sendable {
    public let camera: CameraID
    public let whitepoint: Whitepoint
    /// Maps sensor-native color space to a working color space (e.g. CIE XYZ D50).
    public let forwardMatrix: Matrix3x3
    /// Present in some captures; all-zero when absent.
    public let colorMatrix: Matrix3x3
    public let rgRatio: Float
    public let bgRatio: Float
}

public struct CameraInfo: Sendable {
    public let camera: CameraID
    public let sensor: SensorModel
}

public struct SensorCharacterization: Sendable {
    public let blackLevel: Float
    public let whiteLevel: Float
    public let cliffSlope: Float?

    init(_ pb: Ltpb_SensorCharacterization) {
        blackLevel = pb.blackLevel
        whiteLevel = pb.whiteLevel
        cliffSlope = pb.hasCliffSlope ? pb.cliffSlope : nil
    }
}

public struct SensorData: Sendable {
    public let sensorType: SensorModel
    public let characterization: SensorCharacterization
}

public enum AwbMode: Sendable {
    case auto, daylight, shade, cloudy, tungsten, fluorescent, flash, custom, kelvin

    init(_ pb: Ltpb_ViewPreferences.AWBMode) {
        switch pb {
        case .auto: self = .auto
        case .daylight: self = .daylight
        case .shade: self = .shade
        case .cloudy: self = .cloudy
        case .tungsten: self = .tungsten
        case .fluorescent: self = .fluorescent
        case .flash: self = .flash
        case .custom: self = .custom
        case .kelvin: self = .kelvin
        }
    }
}

public struct AwbGain: Sendable {
    public let r: Float
    public let gr: Float
    public let gb: Float
    public let b: Float

    init(_ pb: Ltpb_ViewPreferences.ChannelGain) {
        r = pb.r
        gr = pb.gR
        gb = pb.gB
        b = pb.b
    }
}
