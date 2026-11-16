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
    /// Writes a "mosaiced raw" DNG for one Bayer capture: the raw sensor
    /// samples plus the CFA pattern and Light's factory colour calibration,
    /// so a real raw converter (Apple's `CIRAWFilter`/ImageIO, Lightroom,
    /// etc.) can demosaic and render it.
    ///
    /// Colour: Light's per-module calibration is in standard DNG form --
    /// `colorMatrix` is an XYZ->camera `ColorMatrix` and `forwardMatrix` is a
    /// white-balanced-camera->XYZ(D50) `ForwardMatrix` (its rows sum to the
    /// D50 white point). We write the illuminant-A and D65 pairs as
    /// calibration 1 and 2. `neutral` is the camera-native RGB of a neutral
    /// surface for this shot (`AsShotNeutral`); see `RawImage.asShotNeutral`.
    /// `baselineExposure` (EV) brings a module captured at a lower gain than
    /// the shot's nominal gain up to the intended brightness.
    ///
    /// `samples` must be in sensor readout order (see `unpackTenBitFrame`).
    public static func write(
        image: RawImage,
        samples: [UInt16],
        blackLevel: Float? = nil,
        orientation: Orientation = .normal,
        neutral: (r: Float, g: Float, b: Float)? = nil,
        baselineExposure: Float = 0
    ) throws -> Data {
        let cfa = image.cfaPattern
        guard cfa != nil || image.sensor == .ar1335Mono else {
            throw DNGWriterError.monoNotYetSupported
        }
        guard samples.count == image.width * image.height else {
            throw DNGWriterError.sampleCountMismatch(expected: image.width * image.height, got: samples.count)
        }

        func usable(_ c: ColorInfo?) -> ColorInfo? {
            guard let c, c.colorMatrix.0 != 0 || c.colorMatrix.4 != 0 else { return nil }
            return c
        }
        let calA = usable(image.color.first { $0.whitepoint == .a })
        let calD65 = usable(image.color.first { $0.whitepoint == .d65 })
        let single = calD65 ?? calA ?? usable(image.color.first)

        var pixelData = Data(count: samples.count * 2)
        pixelData.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self)
            for i in samples.indices { out[i] = samples[i].littleEndian }
        }

        var tiff = TIFFWriter()
        tiff.add(tag: 254, long: 0) // NewSubfileType
        tiff.add(tag: 256, long: UInt32(image.width)) // ImageWidth
        tiff.add(tag: 257, long: UInt32(image.height)) // ImageLength
        tiff.add(tag: 258, short: 16) // BitsPerSample (stored width; real depth is 10, see WhiteLevel)
        tiff.add(tag: 259, short: 1) // Compression: none
        // CFA for the colour modules; LinearRaw (one sample per pixel, no
        // mosaic) for the monochrome module.
        tiff.add(tag: 262, short: cfa != nil ? 32803 : 34892) // PhotometricInterpretation
        tiff.add(tag: 271, ascii: "Light") // Make
        tiff.add(tag: 272, ascii: "L16") // Model
        tiff.add(tag: 273, long: 0) // StripOffsets (patched by TIFFWriter.build)
        tiff.add(tag: 277, short: 1) // SamplesPerPixel
        tiff.add(tag: 278, long: UInt32(image.height)) // RowsPerStrip (single strip)
        tiff.add(tag: 279, long: UInt32(pixelData.count)) // StripByteCounts
        tiff.add(tag: 274, short: orientation.rawValue) // Orientation
        tiff.add(tag: 284, short: 1) // PlanarConfiguration

        if let cfa {
            tiff.add(tag: 33421, shorts: [2, 2]) // CFARepeatPatternDim
            tiff.add(tag: 33422, bytes: cfa.dngBytes) // CFAPattern
        }

        tiff.add(tag: 50706, bytes: [1, 4, 0, 0]) // DNGVersion 1.4
        tiff.add(tag: 50707, bytes: [1, 1, 0, 0]) // DNGBackwardVersion
        tiff.add(tag: 50708, ascii: "Light L16 \(image.camera)".uppercased()) // UniqueCameraModel

        func matrixTag(_ tag: UInt16, _ m: Matrix3x3) {
            tiff.add(tag: tag, srationals: [
                srational(m.0), srational(m.1), srational(m.2),
                srational(m.3), srational(m.4), srational(m.5),
                srational(m.6), srational(m.7), srational(m.8),
            ])
        }

        if cfa != nil {
            if let calA, let calD65 {
                matrixTag(50721, calA.colorMatrix)      // ColorMatrix1
                matrixTag(50722, calD65.colorMatrix)    // ColorMatrix2
                tiff.add(tag: 50778, short: exifLightSource(.a))   // CalibrationIlluminant1
                tiff.add(tag: 50779, short: exifLightSource(.d65)) // CalibrationIlluminant2
                matrixTag(50964, calA.forwardMatrix)    // ForwardMatrix1
                matrixTag(50965, calD65.forwardMatrix)  // ForwardMatrix2
            } else if let single {
                matrixTag(50721, single.colorMatrix)
                tiff.add(tag: 50778, short: exifLightSource(single.whitepoint))
                matrixTag(50964, single.forwardMatrix)
            } else {
                // No factory calibration in this file: generic sRGB D65 XYZ->camera.
                matrixTag(50721, (3.2404542, -1.5371385, -0.4985314,
                                  -0.9692660, 1.8760108, 0.0415560,
                                  0.0556434, -0.2040259, 1.0572252))
                tiff.add(tag: 50778, short: exifLightSource(.d65))
            }

            let n = neutral ?? image.calibratedNeutral(for: .d65) ?? (1, 1, 1)
            tiff.add(tag: 50727, rationals: [(1, 1), (1, 1), (1, 1)]) // AnalogBalance: identity
            tiff.add(tag: 50728, rationals: [rational(n.r), rational(n.g), rational(n.b)]) // AsShotNeutral
        }
        tiff.add(tag: 50730, srationals: [srational(baselineExposure)]) // BaselineExposure (EV)

        // BlackLevel: the real per-sensor value from SensorData when the
        // caller has it; 42 matches the community reference's typical value.
        tiff.add(tag: 50714, long: UInt32(blackLevel ?? 42))
        tiff.add(tag: 50717, long: 1023) // WhiteLevel: true bit depth is 10-bit despite 16-bit storage

        return tiff.build(stripOffsetTag: 273, stripData: pixelData)
    }
}

extension RawImage {
    /// Camera-native RGB of a neutral surface for this shot: from the white
    /// balance the camera chose at capture (`awb_gains`, per-channel
    /// multipliers, so the neutral is their reciprocal), falling back to the
    /// factory D65 calibration.
    public func asShotNeutral(_ metadata: ShotMetadata) -> (r: Float, g: Float, b: Float)? {
        if let g = metadata.awbGain, g.r > 0, g.b > 0, g.gr > 0, g.gb > 0 {
            let green = (g.gr + g.gb) / 2
            return (green / g.r, 1, green / g.b)
        }
        return calibratedNeutral(for: .d65)
    }

    /// EV difference between the shot's nominal exposure (gain x time) and
    /// what this module was actually captured at. Modules in one shot differ:
    /// the reference is often at half the gain of the others, and some run a
    /// shorter exposure.
    public func baselineExposure(_ metadata: ShotMetadata) -> Float {
        guard let shotGain = metadata.imageGain, shotGain > 0 else { return 0 }
        let moduleGain = analogGain * (digitalGain ?? 1)
        guard moduleGain > 0 else { return 0 }
        var ratio = shotGain / moduleGain
        if let shotTime = metadata.imageIntegrationTime, shotTime > 0, exposure > 0 {
            ratio *= Float(shotTime / exposure)
        }
        // The monochrome sensor has no colour filter, so it collects more
        // light than a colour module's green channel at the same settings.
        // Measured on a real shot: about 1.65x (mono mean vs. estimated green
        // level above black), i.e. roughly 0.7 EV to pull back.
        let monoOffset: Float = sensor == .ar1335Mono ? -0.7 : 0
        return max(-3, min(3, log2(ratio) + monoOffset))
    }

    /// Camera-native RGB of a neutral surface under one of the factory
    /// calibration illuminants: `rgRatio`/`bgRatio` are R/G and B/G there.
    public func calibratedNeutral(for whitepoint: Whitepoint) -> (r: Float, g: Float, b: Float)? {
        guard let c = color.first(where: { $0.whitepoint == whitepoint }) ?? color.first,
              c.rgRatio > 0, c.bgRatio > 0 else { return nil }
        return (c.rgRatio, 1, c.bgRatio)
    }
}
