import Foundation
import ImageIO

extension CaptureTime {
    /// The zone's offset from UTC in seconds. The file stores minutes
    /// (a shot taken in California in November carries -480).
    public var utcOffsetSeconds: Int? { rawZoneOffset.map { $0 * 60 } }

    /// The moment the shot was taken. Without a stored zone, the wall-clock
    /// fields are read in the Mac's current zone.
    public var date: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcOffsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard (1...12).contains(month), (1...31).contains(day), year >= 2000 else { return nil }
        return calendar.date(from: parts)
    }

    /// "2026:11:16 14:25:38", the EXIF date form.
    var exifString: String {
        String(format: "%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    /// "-08:00", the EXIF OffsetTime form.
    var exifOffset: String? {
        guard let seconds = utcOffsetSeconds else { return nil }
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }
}

extension ShotMetadata {
    /// The camera records sensor gain, not ISO; gain 1.0 is roughly ISO 100.
    public var isoEquivalent: Int? {
        guard let gain = imageGain, gain > 0 else { return nil }
        return max(10, Int((gain * 100 / 10).rounded()) * 10)
    }

    /// EXIF, TIFF and GPS properties for an exported picture, in the form
    /// ImageIO takes with `CGImageDestinationAddImage`.
    ///
    /// - Parameters:
    ///   - focalLength35: the 35mm-equivalent focal length of what is being
    ///     exported (a lens's own, or the shot's chosen zoom for a merge).
    ///   - lens: the module, for a single-lens export.
    ///   - exposure: the exposure time to record, if it differs from the shot's.
    public func imageProperties(focalLength35: Int? = nil, lens: CameraID? = nil, exposure: TimeInterval? = nil) -> [CFString: Any] {
        var exif: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "Light",
            kCGImagePropertyTIFFModel: deviceModel ?? "L16",
            kCGImagePropertyTIFFSoftware: "L16 Studio",
        ]
        if let captureTime {
            let stamp = captureTime.exifString
            exif[kCGImagePropertyExifDateTimeOriginal] = stamp
            exif[kCGImagePropertyExifDateTimeDigitized] = stamp
            tiff[kCGImagePropertyTIFFDateTime] = stamp
            if let offset = captureTime.exifOffset {
                exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
                exif[kCGImagePropertyExifOffsetTimeDigitized] = offset
                exif[kCGImagePropertyExifOffsetTime] = offset
            }
        }
        if let time = exposure ?? imageIntegrationTime, time > 0 {
            exif[kCGImagePropertyExifExposureTime] = time
        }
        if let iso = isoEquivalent {
            exif[kCGImagePropertyExifISOSpeedRatings] = [iso]
        }
        if let focal = focalLength35 ?? focalLength.map(Int.init), focal > 0 {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = focal
        }
        if let lens {
            exif[kCGImagePropertyExifLensModel] = "L16 \(lens.label) (\(lens.focalLength) mm equivalent)"
        } else {
            exif[kCGImagePropertyExifLensModel] = "L16 merged lenses"
        }
        exif[kCGImagePropertyExifLensMake] = "Light"
        if let flashFired {
            exif[kCGImagePropertyExifFlash] = flashFired ? 1 : 0
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]
        if let latitude, let longitude, abs(latitude) <= 90, abs(longitude) <= 180 {
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W",
            ]
            if let altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude >= 0 ? 0 : 1
            }
            if let heading {
                gps[kCGImagePropertyGPSImgDirection] = heading
                gps[kCGImagePropertyGPSImgDirectionRef] = headingIsTrueNorth ? "T" : "M"
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        return properties
    }
}
