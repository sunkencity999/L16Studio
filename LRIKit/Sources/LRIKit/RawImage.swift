import Foundation

/// The raw, still-encoded sensor data for one capture. Use `LRIKit`'s
/// unpacking functions (task: RAW_PACKED_10BPP / RAW_BAYER_JPEG decoding) to
/// turn this into pixel samples.
public enum RawData: Sendable {
    case packed10bpp(data: Data)
    /// `header` is the full 1576-byte BJPG header (magic + format flag + 4
    /// lengths + 1552 bytes of still-unknown data), preserved verbatim in
    /// case future format understanding needs it.
    case bayerJpeg(header: Data, format: UInt32, jpeg0: Data, jpeg1: Data, jpeg2: Data, jpeg3: Data)
}

/// One camera module's raw capture, plus everything needed to interpret it:
/// dimensions, format, which CFA row/column offset applies, and (once
/// cross-referenced against HwInfo) the sensor model.
public struct RawImage: Sendable {
    public let camera: CameraID
    public var sensor: SensorModel
    public let width: Int
    public let height: Int
    public let format: DataFormat
    public let data: RawData
    /// Bayer CFA red-pixel offset for this specific shot; see `LRI.md`'s
    /// note on `sensor_bayer_red_override` for why this varies per capture.
    public let bayerRedOverride: (x: Int, y: Int)
    public var color: [ColorInfo]
    /// `sensor_is_horizontal_flip` / `sensor_is_vertical_flip` from the
    /// module record: whether the sensor was read out mirrored.
    public var isHorizontalFlip = false
    public var isVerticalFlip = false
    /// Per-module exposure for this frame.
    public var analogGain: Float = 1
    public var digitalGain: Float?
    public var exposure: TimeInterval = 0
    public var lensPosition: Int32 = 0
    public var mirrorPosition: Int32?
}
