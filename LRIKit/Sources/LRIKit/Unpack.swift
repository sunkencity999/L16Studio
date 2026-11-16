import Foundation

public enum UnpackError: Error, CustomStringConvertible {
    case bufferTooSmall(needed: Int, got: Int)

    public var description: String {
        switch self {
        case .bufferTooSmall(let needed, let got):
            "expected at least \(needed) packed bytes, got \(got)"
        }
    }
}

private let tenBitMask: UInt64 = 0b11_1111_1111 // 10 bits

/// Unpacks the L16's RAW_PACKED_10BPP encoding: 4 pixels packed into every 5
/// bytes (40 bits = 4x10 bits, no padding). The packing is unusual -- the
/// packed byte buffer is bit-reversed as a whole before being read as
/// 5-byte/4-pixel groups -- so this is a direct, faithful port of the
/// reference implementation's exact byte order rather than a "cleaned up"
/// reinterpretation; see `Sources/CLRIProto/ATTRIBUTION.md`.
///
/// - Parameters:
///   - packed: the packed input bytes (must contain at least `ceil(count * 10 / 8)` bytes)
///   - count: number of 10-bit pixel samples to produce
/// - Returns: `count` samples, each in 0...1023
public func unpackTenBit(_ packed: Data, count: Int) throws -> [UInt16] {
    let requiredLength = Int(ceil(Double(count) * 10.0 / 8.0))
    guard packed.count >= requiredLength else {
        throw UnpackError.bufferTooSmall(needed: requiredLength, got: packed.count)
    }

    var output = [UInt16](repeating: 0, count: count)

    // Reverse just the prefix we actually need, matching the reference's
    // `packd[..required_len_packd].to_vec(); packd.reverse()`.
    let prefix = Array(packed.prefix(requiredLength))
    let reversed = Array(prefix.reversed())

    let fullGroupCount = reversed.count / 5
    for groupIndex in 0..<fullGroupCount {
        let base = groupIndex * 5
        let long =
            (UInt64(reversed[base]) << 32) |
            (UInt64(reversed[base + 1]) << 24) |
            (UInt64(reversed[base + 2]) << 16) |
            (UInt64(reversed[base + 3]) << 8) |
            UInt64(reversed[base + 4])

        let b4 = long & tenBitMask
        let b3 = (long >> 10) & tenBitMask
        let b2 = (long >> 20) & tenBitMask
        let b1 = (long >> 30) & tenBitMask

        let outIndex = groupIndex * 4
        output[outIndex] = UInt16(b1)
        output[outIndex + 1] = UInt16(b2)
        output[outIndex + 2] = UInt16(b3)
        output[outIndex + 3] = UInt16(b4)
    }

    // Leftover bytes (when `count` isn't a multiple of 4) are interpreted
    // little-endian, LSB-first -- deliberately different from the main loop;
    // this only ever matters for a file's very last, partial group of pixels.
    let remainderBytes = reversed.count % 5
    if remainderBytes > 0 {
        var longBytes = [UInt8](repeating: 0, count: 8)
        let remainderStart = fullGroupCount * 5
        for i in 0..<remainderBytes {
            longBytes[i] = reversed[remainderStart + i]
        }
        var long: UInt64 = 0
        for i in 0..<8 {
            long |= UInt64(longBytes[i]) << (8 * i)
        }

        let countRemainder = count % 4
        let start = count - countRemainder
        for i in 0..<countRemainder {
            output[start + i] = UInt16((long >> (10 * i)) & tenBitMask)
        }
    }

    return output
}

/// Unpacks a whole sensor frame into row-major, top-left-first samples.
///
/// `unpackTenBit` is a faithful port of the reference decoder, which reverses
/// the byte buffer before reading it -- so its output is the frame in
/// *reversed* pixel order (the image rotated 180 degrees). That is harmless
/// for statistics but wrong for pictures: the image is upside down and,
/// because the dimensions are even, the Bayer phase is shifted by one in both
/// axes, which swaps red and blue relative to `sensor_bayer_red_override`.
/// Confirmed against the camera's own JPEG of the same shot (2026-11-16).
public func unpackTenBitFrame(_ packed: Data, count: Int) throws -> [UInt16] {
    var samples = try unpackTenBit(packed, count: count)
    samples.reverse()
    return samples
}

extension RawImage {
    /// Unpacked 10-bit samples in sensor readout order (row-major, top-left
    /// first -- see `unpackTenBitFrame`), if this capture is in `RAW_PACKED_10BPP`
    /// format. Returns `nil` for `RAW_BAYER_JPEG` captures -- use
    /// `decodedBayerPlanes()` for those instead.
    public func unpackedSamples() throws -> [UInt16]? {
        guard case .packed10bpp(let data) = data else { return nil }
        return try unpackTenBitFrame(data, count: width * height)
    }
}
