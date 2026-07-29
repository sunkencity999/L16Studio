import Foundation

/// EXIF/TIFF LightSource codes DNG reuses for CalibrationIlluminant1/2.
/// The CIE fluorescent standards (F2/F7/F11) have no exact EXIF code; these
/// are the closest approximations.
private func exifLightSource(_ w: Whitepoint) -> UInt16 {
    switch w {
    case .a: 17
    case .d50: 23
    case .d65: 21
    case .d75: 22
    case .f2: 14
    case .f7: 21
    case .f11: 14
    case .tl84: 14
    case .unknown: 0
    }
}

private func srational(_ value: Float, denominator: Int32 = 1_000_000) -> (Int32, Int32) {
    (Int32((value * Float(denominator)).rounded()), denominator)
}

private func rational(_ value: Float, denominator: UInt32 = 1_000_000) -> (UInt32, UInt32) {
    (UInt32(max(0, (value * Float(denominator)).rounded())), denominator)
}

public enum DNGWriterError: Error, CustomStringConvertible {
    case monoNotYetSupported
    case sampleCountMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .monoNotYetSupported: "writing DNGs for monochrome captures isn't implemented yet"
        case .sampleCountMismatch(let expected, let got): "expected \(expected) samples, got \(got)"
        }
    }
}

public enum DNGWriter {
    /// Writes a minimal, valid "mosaiced raw" DNG for one Bayer capture:
    /// the raw sensor samples plus the CFA pattern and color calibration
    /// needed for a real raw converter (Apple's `CIRAWFilter`/ImageIO, or
    /// Lightroom/etc.) to debayer and render it -- we don't do demosaicing
    /// ourselves, we hand off to macOS's existing, mature raw pipeline.
    /// Validated against a real capture: `CIRAWFilter` accepts this output
    /// and produces a correctly demosaiced (no color moire/aliasing) image,
    /// which conclusively confirms the CFA-pattern-from-`sensor_bayer_red_
    /// override` logic in `CFAPattern.swift` is correct.
    ///
    /// **Known open issue -- color is not yet accurate.** Light's own
    /// `forwardMatrix`/`colorMatrix` calibration data (tried both directly
    /// as `ColorMatrix1` and inverted) produces a heavily saturated green
    /// cast when run through `CIRAWFilter` -- likely because Light's matrices
    /// were calibrated for their own `CIAPI`/`libcp` rendering pipeline
    /// (see the LRI-format research), not for DNG's specific colorimetric
    /// convention, and may need a different combination/normalization than
    /// DNG expects. A generic sRGB D65 XYZ->camera matrix produces a far
    /// more plausible (if not perfectly accurate) result, so that's the
    /// current default. Also observed: `CIRAWFilter` appears to ignore our
    /// `AsShotNeutral` tag entirely (real vs. identity values produced
    /// near-identical output) -- worth investigating further, possibly a
    /// `CIRAWFilter` option needs to be set explicitly rather than relying
    /// on defaults. Revisit both before trusting color output for anything
    /// beyond "a recognizable photo."
    public static func write(image: RawImage, samples: [UInt16], blackLevel: Float? = nil, orientation: Orientation = .normal) throws -> Data {
        guard let cfa = image.cfaPattern else {
            throw DNGWriterError.monoNotYetSupported
        }
        guard samples.count == image.width * image.height else {
            throw DNGWriterError.sampleCountMismatch(expected: image.width * image.height, got: samples.count)
        }

        // Prefer daylight-ish calibration (matches RawImage.daylight() in the
        // Rust reference: F7, falling back to D65), then just take whatever's there.
        // Not currently used for ColorMatrix1 (see doc comment above) but kept
        // for AsShotNeutral and CalibrationIlluminant1.
        let color = image.color.first(where: { $0.whitepoint == .f7 })
            ?? image.color.first(where: { $0.whitepoint == .d65 })
            ?? image.color.first

        // Generic sRGB D65 XYZ->camera matrix -- see doc comment above for
        // why we're not using Light's own calibration matrix here yet.
        let colorMatrix1: Matrix3x3 = (
            3.2404542, -1.5371385, -0.4985314,
            -0.9692660, 1.8760108, 0.0415560,
            0.0556434, -0.2040259, 1.0572252
        )

        var pixelData = Data(capacity: samples.count * 2)
        for s in samples {
            pixelData.append(UInt8(s & 0xff))
            pixelData.append(UInt8((s >> 8) & 0xff))
        }

        var tiff = TIFFWriter()
        tiff.add(tag: 254, long: 0) // NewSubfileType
        tiff.add(tag: 256, long: UInt32(image.width)) // ImageWidth
        tiff.add(tag: 257, long: UInt32(image.height)) // ImageLength
        tiff.add(tag: 258, short: 16) // BitsPerSample (stored width; real depth is 10, see WhiteLevel)
        tiff.add(tag: 259, short: 1) // Compression: none
        tiff.add(tag: 262, short: 32803) // PhotometricInterpretation: CFA
        tiff.add(tag: 271, ascii: "Light") // Make
        tiff.add(tag: 272, ascii: "L16") // Model
        tiff.add(tag: 273, long: 0) // StripOffsets (patched by TIFFWriter.build)
        tiff.add(tag: 277, short: 1) // SamplesPerPixel
        tiff.add(tag: 278, long: UInt32(image.height)) // RowsPerStrip (single strip)
        tiff.add(tag: 279, long: UInt32(pixelData.count)) // StripByteCounts
        tiff.add(tag: 274, short: orientation.rawValue) // Orientation
        tiff.add(tag: 284, short: 1) // PlanarConfiguration

        tiff.add(tag: 33421, shorts: [2, 2]) // CFARepeatPatternDim
        tiff.add(tag: 33422, bytes: cfa.dngBytes) // CFAPattern

        tiff.add(tag: 50706, bytes: [1, 4, 0, 0]) // DNGVersion 1.4
        tiff.add(tag: 50707, bytes: [1, 1, 0, 0]) // DNGBackwardVersion
        tiff.add(tag: 50708, ascii: "Light L16") // UniqueCameraModel

        tiff.add(tag: 50721, srationals: [
            srational(colorMatrix1.0), srational(colorMatrix1.1), srational(colorMatrix1.2),
            srational(colorMatrix1.3), srational(colorMatrix1.4), srational(colorMatrix1.5),
            srational(colorMatrix1.6), srational(colorMatrix1.7), srational(colorMatrix1.8),
        ]) // ColorMatrix1

        if let color {
            tiff.add(tag: 50778, short: exifLightSource(color.whitepoint)) // CalibrationIlluminant1

            // AsShotNeutral: the camera-native RGB triplet that should render
            // neutral. Convention here (rgRatio/bgRatio as G-normalized
            // ratios) is a best-effort read of the calibration data -- see
            // the "known open issue" doc comment above, CIRAWFilter doesn't
            // appear to be using this tag at all currently.
            tiff.add(tag: 50728, rationals: [(1, 1), (1, 1), (1, 1)]) // AnalogBalance: identity
            tiff.add(tag: 50729, rationals: [
                rational(color.rgRatio), rational(1.0), rational(color.bgRatio),
            ]) // AsShotNeutral
        }

        // BlackLevel: use the real per-sensor value from SensorData if the
        // caller has it (ShotMetadata.sensorData, keyed by sensor model, not
        // per-image -- so it's threaded in as a parameter rather than read
        // from `image` directly); 42 is a fallback matching the value the
        // community's reference implementation hardcoded as typical.
        tiff.add(tag: 50714, long: UInt32(blackLevel ?? 42))
        tiff.add(tag: 50717, long: 1023) // WhiteLevel: true bit depth is 10-bit despite 16-bit storage

        return tiff.build(stripOffsetTag: 273, stripData: pixelData)
    }
}
