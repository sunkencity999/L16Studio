import Foundation
import LRIKit

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
        }
    } catch {
        print("ERROR: \(error)")
    }
    print("")
}
