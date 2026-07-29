import Foundation
import LRIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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

for path in arguments.dropFirst() {
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
        print("on tripod: \(file.metadata.onTripod.map(String.init) ?? "?")")
        let lat = file.metadata.latitude
        let lon = file.metadata.longitude
        print("gps: \(lat ?? .nan), \(lon ?? .nan)")
        print("sensor data entries: \(file.metadata.sensorData.count)")
        print("camera infos (hw map): \(file.cameraInfos.count)")
        print("image count: \(file.images.count)")

        for image in file.images {
            let formatDesc: String
            switch image.data {
            case .packed10bpp(let d): formatDesc = "packed10bpp(\(d.count) bytes)"
            case .bayerJpeg(_, let fmt, let j0, let j1, let j2, let j3):
                formatDesc = "bayerJpeg(format=\(fmt), jpeg0=\(j0.count)b, jpeg1=\(j1.count)b, jpeg2=\(j2.count)b, jpeg3=\(j3.count)b)"
            }
            print("  [\(image.camera)] \(image.width)x\(image.height) sensor=\(image.sensor) sbro=\(image.bayerRedOverride) colors=\(image.color.count) data=\(formatDesc)")

            if let samples = try image.unpackedSamples() {
                let minV = samples.min() ?? 0
                let maxV = samples.max() ?? 0
                let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
                print("      unpacked \(samples.count) samples: min=\(minV) max=\(maxV) mean=\(String(format: "%.1f", mean))")

                if image.camera == file.metadata.referenceCamera {
                    let preview = quickPreview(samples: samples, width: image.width, height: image.height)
                    let outURL = url.deletingLastPathComponent()
                        .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(image.camera)_preview.png")
                    writeGrayscalePNG(samples: preview.samples, width: preview.width, height: preview.height, maxValue: 1023, to: outURL)
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
