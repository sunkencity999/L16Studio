import Foundation
import SwiftProtobuf

/// Everything from a shot's `ViewPreferences`/`LightHeader` blocks that isn't
/// a per-lens image: exposure/AWB/HDR settings, GPS, AF result, etc.
public struct ShotMetadata: Sendable {
    public var referenceCamera: CameraID?
    public var firmwareVersion: String?
    public var focalLength: Int32?
    public var imageGain: Float?
    public var imageIntegrationTime: TimeInterval?
    public var afAchieved: Bool?
    public var hdrMode: HdrMode?
    public var sceneMode: SceneMode?
    public var onTripod: Bool?
    public var awbMode: AwbMode?
    public var awbGain: AwbGain?
    public var orientation: Orientation?
    public var sensorData: [SensorData] = []
    public var latitude: Double?
    public var longitude: Double?
}

public struct LRIFile: Sendable {
    public let images: [RawImage]
    public let cameraInfos: [CameraInfo]
    public let metadata: ShotMetadata

    public var referenceImage: RawImage? {
        guard let ref = metadata.referenceCamera else { return nil }
        return images.first { $0.camera == ref }
    }

    /// Parses an entire `.LRI` file: walks its length-prefixed blocks,
    /// decodes each block's protobuf message by type, and assembles the
    /// per-lens `RawImage`s and shot metadata. See `Block.swift` for the
    /// block container format and `Sources/CLRIProto/ATTRIBUTION.md` for
    /// where this format understanding comes from.
    public static func decode(_ data: Data) throws -> LRIFile {
        var images: [RawImage] = []
        var colors: [ColorInfo] = []
        var cameraInfos: [CameraInfo] = []
        var metadata = ShotMetadata()

        var remaining = data
        while !remaining.isEmpty {
            let (block, length) = try LRIBlock.parse(from: remaining)
            try extract(from: block, images: &images, colors: &colors, cameraInfos: &cameraInfos, metadata: &metadata)
            remaining = remaining.subdata(in: (remaining.startIndex + length)..<remaining.endIndex)
        }

        // Second pass: backfill each image's sensor model + color profiles
        // now that we've seen every block (HwInfo and ColorCalibration can
        // arrive in different blocks than the RawImage they describe).
        for i in images.indices {
            if let info = cameraInfos.first(where: { $0.camera == images[i].camera }) {
                images[i].sensor = info.sensor
            }
            images[i].color = colors.filter { $0.camera == images[i].camera }
        }

        return LRIFile(images: images, cameraInfos: cameraInfos, metadata: metadata)
    }

    private static func extract(
        from block: LRIBlock,
        images: inout [RawImage],
        colors: inout [ColorInfo],
        cameraInfos: inout [CameraInfo],
        metadata: inout ShotMetadata
    ) throws {
        switch block.type {
        case .gpsData:
            // GPSData blocks are rare in practice; not required for a first
            // decode, so we don't fail the whole file if this one is malformed.
            if let gps = try? Ltpb_GPSData(serializedBytes: block.message) {
                if gps.hasLatitude { metadata.latitude = gps.latitude }
                if gps.hasLongitude { metadata.longitude = gps.longitude }
            }
            return

        case .viewPreferences:
            do {
                let vp = try Ltpb_ViewPreferences(serializedBytes: block.message)
                apply(vp, to: &metadata)
            } catch {
                throw LRIParseError.malformedProtobuf(underlying: error)
            }
            return

        case .lightHeader:
            break
        }

        let header: Ltpb_LightHeader
        do {
            header = try Ltpb_LightHeader(serializedBytes: block.message)
        } catch {
            throw LRIParseError.malformedProtobuf(underlying: error)
        }

        for hwInfo in header.hasHwInfo ? [header.hwInfo] : [] {
            for camInfo in hwInfo.camera {
                cameraInfos.append(CameraInfo(camera: CameraID(camInfo.id), sensor: SensorModel(camInfo.sensor)))
            }
        }

        if header.hasViewPreferences {
            apply(header.viewPreferences, to: &metadata)
        }

        for moduleCal in header.moduleCalibration {
            let camera = CameraID(moduleCal.cameraID)
            for color in moduleCal.color {
                // Rust reference: skip entries with no forward matrix, since
                // that's the one we actually need to do anything useful.
                guard color.hasForwardMatrix else { continue }
                colors.append(ColorInfo(
                    camera: camera,
                    whitepoint: Whitepoint(color.type),
                    forwardMatrix: matrix3x3(color.forwardMatrix),
                    colorMatrix: color.hasColorMatrix ? matrix3x3(color.colorMatrix) : (0, 0, 0, 0, 0, 0, 0, 0, 0),
                    rgRatio: color.rgRatio,
                    bgRatio: color.bgRatio
                ))
            }
        }

        for module in header.modules {
            guard module.hasSensorDataSurface else { continue }
            let surface = module.sensorDataSurface
            let width = Int(surface.size.x)
            let height = Int(surface.size.y)
            let offset = Int(surface.dataOffset)

            guard let format = DataFormat(surface.format) else { continue }

            let rawData: RawData
            switch format {
            case .packed10bpp:
                let length = Int(surface.rowStride) * height
                guard offset + length <= block.data.count else {
                    throw LRIParseError.tooShort(context: "packed10bpp image data for \(module.id)")
                }
                let base = block.data.startIndex + offset
                rawData = .packed10bpp(data: block.data.subdata(in: base..<(base + length)))

            case .bayerJpeg:
                rawData = try parseBayerJpeg(in: block.data, at: offset)
            }

            let sbro = module.sensorBayerRedOverride
            var image = RawImage(
                camera: CameraID(module.id),
                sensor: .unknown, // backfilled in decode() once all blocks are seen
                width: width,
                height: height,
                format: format,
                data: rawData,
                bayerRedOverride: (Int(sbro.x), Int(sbro.y)),
                color: []
            )
            image.isHorizontalFlip = module.sensorIsHorizontalFlip
            image.isVerticalFlip = module.sensorIsVerticalFlip
            image.analogGain = module.sensorAnalogGain
            image.digitalGain = module.hasSensorDigitalGain ? module.sensorDigitalGain : nil
            image.exposure = TimeInterval(module.sensorExposure) / 1_000_000_000
            image.lensPosition = module.lensPosition
            image.mirrorPosition = module.hasMirrorPosition ? module.mirrorPosition : nil
            images.append(image)
        }

        if header.hasImageReferenceCamera {
            metadata.referenceCamera = CameraID(header.imageReferenceCamera)
        }
        if header.hasAfInfo, header.afInfo.hasFocusAchieved {
            metadata.afAchieved = header.afInfo.focusAchieved
        }
        if header.hasDeviceFwVersion {
            metadata.firmwareVersion = header.deviceFwVersion
        }
        if header.hasImageFocalLength {
            metadata.focalLength = header.imageFocalLength
        }
        for sd in header.sensorData {
            metadata.sensorData.append(SensorData(
                sensorType: SensorModel(sd.type),
                characterization: SensorCharacterization(sd.data)
            ))
        }
    }

    /// `BJPG` header: 4-byte magic, u32 format flag, 4x u32 JPEG plane
    /// lengths, then 1552 bytes the community hasn't decoded yet (see
    /// `bayer_jpeg.md` in the reference repo) -- 1576 bytes total before the
    /// JPEG plane data begins.
    private static func parseBayerJpeg(in blockData: Data, at offset: Int) throws -> RawData {
        let headerLength = 1576
        let base = blockData.startIndex + offset
        guard base + headerLength <= blockData.endIndex else {
            throw LRIParseError.tooShort(context: "BJPG header")
        }

        let magic = blockData.subdata(in: base..<(base + 4))
        guard Array(magic) == Array("BJPG".utf8) else {
            throw LRIParseError.badMagic
        }

        let format = blockData.readUInt32LE(at: base + 4)
        let len0 = Int(blockData.readUInt32LE(at: base + 8))
        let len1 = Int(blockData.readUInt32LE(at: base + 12))
        let len2 = Int(blockData.readUInt32LE(at: base + 16))
        let len3 = Int(blockData.readUInt32LE(at: base + 20))

        let header = blockData.subdata(in: base..<(base + headerLength))
        var cursor = base + headerLength

        func take(_ length: Int) throws -> Data {
            guard cursor + length <= blockData.endIndex else {
                throw LRIParseError.tooShort(context: "BJPG plane data")
            }
            let slice = blockData.subdata(in: cursor..<(cursor + length))
            cursor += length
            return slice
        }

        let jpeg0 = try take(len0)
        // format == 1 (monochrome): only jpeg0 is present, one full-res plane.
        // format == 0 (color): four half-res planes, one per Bayer position.
        if format == 1 {
            return .bayerJpeg(header: header, format: format, jpeg0: jpeg0, jpeg1: Data(), jpeg2: Data(), jpeg3: Data())
        }
        let jpeg1 = try take(len1)
        let jpeg2 = try take(len2)
        let jpeg3 = try take(len3)
        return .bayerJpeg(header: header, format: format, jpeg0: jpeg0, jpeg1: jpeg1, jpeg2: jpeg2, jpeg3: jpeg3)
    }

    private static func apply(_ vp: Ltpb_ViewPreferences, to metadata: inout ShotMetadata) {
        if vp.hasImageIntegrationTimeNs {
            metadata.imageIntegrationTime = TimeInterval(vp.imageIntegrationTimeNs) / 1_000_000_000
        }
        if vp.hasImageGain {
            metadata.imageGain = vp.imageGain
        }
        if vp.hasHdrMode {
            metadata.hdrMode = HdrMode(vp.hdrMode)
        }
        if vp.hasSceneMode {
            metadata.sceneMode = SceneMode(vp.sceneMode)
        }
        if vp.hasIsOnTripod {
            metadata.onTripod = vp.isOnTripod
        }
        if vp.hasAwbMode {
            metadata.awbMode = AwbMode(vp.awbMode)
        }
        if vp.hasAwbGains {
            metadata.awbGain = AwbGain(vp.awbGains)
        }
        if vp.hasOrientation {
            metadata.orientation = Orientation(vp.orientation)
        }
    }
}
