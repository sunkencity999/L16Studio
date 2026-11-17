import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import LRIKit

final class MetadataTests: XCTestCase {
    func testCaptureTimeUsesStoredZone() throws {
        let time = CaptureTime(year: 2026, month: 11, day: 16, hour: 14, minute: 25, second: 38, rawZoneOffset: -480)
        XCTAssertEqual(time.utcOffsetSeconds, -8 * 3600)
        XCTAssertEqual(time.exifString, "2026:11:16 14:25:38")
        XCTAssertEqual(time.exifOffset, "-08:00")
        let date = try XCTUnwrap(time.date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.component(.hour, from: date), 22)
        XCTAssertEqual(CaptureTime(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0, rawZoneOffset: 330).exifOffset, "+05:30")
        XCTAssertNil(CaptureTime(year: 0, month: 0, day: 0, hour: 0, minute: 0, second: 0, rawZoneOffset: nil).date)
    }

    func testPropertiesCarryLocationOnlyWhenKnown() {
        var metadata = ShotMetadata()
        XCTAssertNil(metadata.imageProperties()[kCGImagePropertyGPSDictionary])
        metadata.latitude = -33.86
        metadata.longitude = 151.21
        metadata.altitude = 12
        let gps = metadata.imageProperties()[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual(gps?[kCGImagePropertyGPSLongitudeRef] as? String, "E")
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double, 33.86)
    }

    /// Exports a real shot and reads the file back. Skipped without test data.
    func testExportedFilesCarryCaptureDetails() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test-data/L16_00003.lri")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("no test shot") }
        let file = try LRIFile.decode(Data(contentsOf: source, options: .mappedIfSafe))
        let lens = try XCTUnwrap(file.referenceImage)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l16-metadata-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func properties(_ url: URL) throws -> [CFString: Any] {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        }

        let renderer = try LensRenderer(image: lens, file: file)
        for (name, type) in [("a.jpg", UTType.jpeg), ("a.heic", UTType.heic)] {
            let url = folder.appendingPathComponent(name)
            try renderer.export(to: url, type: type)
            let p = try properties(url)
            let exif = try XCTUnwrap(p[kCGImagePropertyExifDictionary] as? [CFString: Any], name)
            let tiff = try XCTUnwrap(p[kCGImagePropertyTIFFDictionary] as? [CFString: Any], name)
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:11:16 14:25:38", name)
            XCTAssertEqual(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String, "-08:00", name)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Light", name)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "L16", name)
            XCTAssertNotNil(exif[kCGImagePropertyExifExposureTime], name)
            XCTAssertNotNil(exif[kCGImagePropertyExifISOSpeedRatings], name)
            XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, lens.camera.focalLength, name)
            XCTAssertNil(p[kCGImagePropertyGPSDictionary], "this shot had no GPS fix")
        }

        let dng = folder.appendingPathComponent("a.dng")
        try ImageRenderer.exportDNG(lens, from: file, to: dng)
        let tiff = try XCTUnwrap(try properties(dng)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFDateTime] as? String, "2026:11:16 14:25:38")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "L16")
    }
}
