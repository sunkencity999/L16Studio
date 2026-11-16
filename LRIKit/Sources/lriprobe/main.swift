import Foundation
import LRIKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

func exportAndRender(image: RawImage, file: LRIFile, baseURL: URL) {
    do {
        let dngURL = baseURL.deletingPathExtension().appendingPathExtension("dng")
        try ImageRenderer.exportDNG(image, from: file, to: dngURL)
        print("      wrote DNG: \(dngURL.path)")

        let jpegURL = baseURL.deletingPathExtension().appendingPathExtension("rendered.jpg")
        try ImageRenderer.exportJPEG(image, from: file, to: jpegURL)
        print("      wrote rendered JPEG: \(jpegURL.path)")

        let heicURL = baseURL.deletingPathExtension().appendingPathExtension("rendered.heic")
        try ImageRenderer.exportHEIC(image, from: file, to: heicURL)
        print("      wrote rendered HEIC: \(heicURL.path)")
    } catch {
        print("      export error: \(error)")
    }
}

func writeGrayscalePNG(samples: [UInt16], width: Int, height: Int, maxValue: UInt16, to url: URL) {
    var eightBit = [UInt8](repeating: 0, count: width * height)
    for i in 0..<samples.count {
        eightBit[i] = UInt8(min(255, Int(samples[i]) * 255 / Int(maxValue)))
    }
    guard let context = CGContext(
        data: &eightBit, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ), let cgImage = context.makeImage() else {
        print("      (failed to build preview image)")
        return
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("      (failed to create PNG destination)")
        return
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    print("      wrote preview: \(url.path)")
}

/// Crude nearest-neighbor "debayer" (just downsamples 2x2 tiles to their
/// average) purely for a quick visual sanity check -- NOT the real pipeline.
func quickPreview(samples: [UInt16], width: Int, height: Int) -> (samples: [UInt16], width: Int, height: Int) {
    let outW = width / 2
    let outH = height / 2
    var out = [UInt16](repeating: 0, count: outW * outH)
    for y in 0..<outH {
        for x in 0..<outW {
            let i00 = (y * 2) * width + (x * 2)
            let i01 = i00 + 1
            let i10 = i00 + width
            let i11 = i10 + 1
            let sum = Int(samples[i00]) + Int(samples[i01]) + Int(samples[i10]) + Int(samples[i11])
            out[y * outW + x] = UInt16(sum / 4)
        }
    }
    return (out, outW, outH)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: lriprobe <file.lri> [...]")
    exit(1)
}

for path in arguments.dropFirst() where !path.hasPrefix("--") {
    print("=== \(path) ===")
    let url = URL(fileURLWithPath: path)
    do {
        let data = try Data(contentsOf: url)
        print("file size: \(data.count) bytes")
        let file = try LRIFile.decode(data)

        print("firmware: \(file.metadata.firmwareVersion ?? "?")")
        print("focal length: \(file.metadata.focalLength.map(String.init) ?? "?")")
        print("reference camera: \(file.metadata.referenceCamera.map(String.init(describing:)) ?? "?")")
        print("hdr mode: \(file.metadata.hdrMode.map(String.init(describing:)) ?? "?")")
        print("scene mode: \(file.metadata.sceneMode.map(String.init(describing:)) ?? "?")")
        print("awb mode: \(file.metadata.awbMode.map(String.init(describing:)) ?? "?")")
        print("awb gains: \(file.metadata.awbGain.map { "r=\($0.r) gr=\($0.gr) gb=\($0.gb) b=\($0.b)" } ?? "?")")
        print("orientation: \(file.metadata.orientation.map(String.init(describing:)) ?? "?")")
        print("image gain: \(file.metadata.imageGain.map { String($0) } ?? "?")  integration: \(file.metadata.imageIntegrationTime.map { String($0) } ?? "?") s")
        print("on tripod: \(file.metadata.onTripod.map(String.init) ?? "?")")
        let lat = file.metadata.latitude
        let lon = file.metadata.longitude
        print("gps: \(lat ?? .nan), \(lon ?? .nan)")
        print("sensor data entries: \(file.metadata.sensorData.count)")
        print("camera infos (hw map): \(file.cameraInfos.count)")
        print("image count: \(file.images.count)")

        if CommandLine.arguments.contains("--mono-dng") {
            // Writes the monochrome module as a LinearRaw DNG.
            for image in file.images where image.sensor == .ar1335Mono {
                let out = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(image.camera)_mono.dng")
                try ImageRenderer.exportDNG(image, from: file, to: out)
                print("wrote \(out.lastPathComponent)")
            }
            continue
        }

        if CommandLine.arguments.contains("--fuse-tele") {
            // Full fusion: wide merge plus telephoto detail, at the shot's focal length.
            let scale = CommandLine.arguments.first { $0.hasPrefix("--scale=") }.flatMap { Float($0.dropFirst(8)) }
            let (fused, report) = try TeleFusion.fuse(file: file, scale: scale) { message, fraction in
                print(String(format: "  fuse %3.0f%%  %@", fraction * 100, message))
            }
            let base = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_fused_tele")
            if let dest = CGImageDestinationCreateWithURL(base.appendingPathExtension("jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, fused, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            print(String(format: "full fusion: %.0f x %.0f (%.1f MP), %.2fx, %.1f s", report.outputSize.width, report.outputSize.height,
                         Double(report.outputSize.width * report.outputSize.height) / 1e6, report.scale, report.seconds))
            for f in report.wide.frames {
                print(String(format: "  wide %@: accepted over %.0f%%", f.camera.label, f.coverage * 100))
            }
            for t in report.tiles {
                print(String(format: "  tele %@: at (%.0f, %.0f) in the wide frame, match %.2f, alignment trusted in %.0f%% of its footprint, detail over %.0f%% of the output",
                             t.camera.label, t.origin.x, t.origin.y, t.placementScore, t.aligned * 100, t.coverage * 100))
            }
            continue
        }

        if CommandLine.arguments.contains("--fuse") {
            // Stage-one fusion: merge the lenses that share the reference's focal length.
            let (fused, report) = try WideFusion.fuse(file: file) { message, fraction in
                print(String(format: "  fuse %3.0f%%  %@", fraction * 100, message))
            }
            let outURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_fused.tif")
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.tiff" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, fused, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            let jpegURL = outURL.deletingPathExtension().appendingPathExtension("jpg")
            if let dest = CGImageDestinationCreateWithURL(jpegURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, fused, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            print("fused \(report.frames.count + 1) lenses onto \(report.reference.label) in \(String(format: "%.1f", report.seconds)) s -> \(outURL.lastPathComponent)")
            for f in report.frames {
                print(String(format: "  %@: median shift %.1f px, max %.1f px, accepted over %.0f%% of the frame",
                             f.camera.label, f.medianShift, f.maxShift, f.coverage * 100))
            }
            continue
        }

        for image in file.images {
            let formatDesc: String
            switch image.data {
            case .packed10bpp(let d): formatDesc = "packed10bpp(\(d.count) bytes)"
            case .bayerJpeg(_, let fmt, let j0, let j1, let j2, let j3):
                formatDesc = "bayerJpeg(format=\(fmt), jpeg0=\(j0.count)b, jpeg1=\(j1.count)b, jpeg2=\(j2.count)b, jpeg3=\(j3.count)b)"
            }
            print("  [\(image.camera)] \(image.width)x\(image.height) sensor=\(image.sensor) sbro=\(image.bayerRedOverride) hflip=\(image.isHorizontalFlip) vflip=\(image.isVerticalFlip) again=\(image.analogGain) dgain=\(image.digitalGain.map { String($0) } ?? "-") exp=\(image.exposure)s lens=\(image.lensPosition) mirror=\(image.mirrorPosition.map { String($0) } ?? "-") colors=\(image.color.count) data=\(formatDesc)")
            for c in image.color {
                print("      color[\(c.whitepoint)]: rg=\(c.rgRatio) bg=\(c.bgRatio) forward=\(c.forwardMatrix) color=\(c.colorMatrix)")
            }

            if let samples = try image.unpackedSamples() {
                let minV = samples.min() ?? 0
                let maxV = samples.max() ?? 0
                let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
                print("      unpacked \(samples.count) samples: min=\(minV) max=\(maxV) mean=\(String(format: "%.1f", mean))")

                if CommandLine.arguments.contains("--thumbs"), image.cfaPattern != nil || image.sensor == .ar1335Mono {
                    // One small render per colour module, for eyeballing
                    // per-lens colour and orientation side by side.
                    let thumbURL = url.deletingLastPathComponent()
                        .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(image.camera)_thumb.jpg")
                    if let cg = try? ImageRenderer.renderThumbnail(image, from: file, maxDimension: 640),
                       let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cg, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }

                if image.camera == file.metadata.referenceCamera {
                    let preview = quickPreview(samples: samples, width: image.width, height: image.height)
                    let outURL = url.deletingLastPathComponent()
                        .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(image.camera)_preview.png")
                    writeGrayscalePNG(samples: preview.samples, width: preview.width, height: preview.height, maxValue: 1023, to: outURL)

                    if image.cfaPattern != nil {
                        let exportBaseURL = url.deletingLastPathComponent()
                            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(image.camera)")
                        exportAndRender(image: image, file: file, baseURL: exportBaseURL)
                    }
                }
            } else if case .bayerJpeg = image.data {
                let planes = try image.decodedBayerPlanes()
                for (i, plane) in planes.enumerated() {
                    let minV = plane.samples.min() ?? 0
                    let maxV = plane.samples.max() ?? 0
                    print("      plane \(i): \(plane.width)x\(plane.height) min=\(minV) max=\(maxV)")
                }
            }
        }
    } catch {
        print("ERROR: \(error)")
    }
    print("")
}
