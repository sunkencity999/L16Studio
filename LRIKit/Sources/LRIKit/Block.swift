import Foundation

/// The kind of protobuf message a block carries.
///
/// Format documented by the `lri-rs`/`luminat` community reverse-engineering
/// projects (see `Sources/CLRIProto/ATTRIBUTION.md`).
public enum BlockType: UInt8 {
    case lightHeader = 0
    case viewPreferences = 1
    case gpsData = 2
}

public enum LRIParseError: Error, CustomStringConvertible {
    case tooShort(context: String)
    case badMagic
    case unknownBlockType(UInt8)
    case malformedProtobuf(underlying: Error)

    public var description: String {
        switch self {
        case .tooShort(let context): "data too short: \(context)"
        case .badMagic: "block magic number is not \"LELR\""
        case .unknownBlockType(let t): "unknown block type \(t)"
        case .malformedProtobuf(let e): "malformed protobuf message: \(e)"
        }
    }
}

/// A single 32-byte-header block within an .LRI file.
///
/// Header layout (little-endian):
/// | bytes | field            |
/// |-------|------------------|
/// | 4     | magic "LELR"     |
/// | 8     | block_length     |
/// | 8     | message_offset (from block start, i.e. includes the 32-byte header) |
/// | 4     | message_length   |
/// | 1     | block type       |
/// | 7     | reserved         |
public struct LRIBlock {
    public static let headerSize = 32
    private static let magic: [UInt8] = Array("LELR".utf8)

    public let type: BlockType
    public let messageOffset: Int
    public let messageLength: Int
    /// The full block, including its 32-byte header. Offsets in `messageOffset`
    /// and any `Surface.dataOffset` values are relative to the start of this slice.
    public let data: Data

    public var message: Data {
        data.subdata(in: messageOffset..<(messageOffset + messageLength))
    }

    /// Parses a single block starting at `data`'s start index. Returns the
    /// parsed block and the number of bytes it occupies, so callers can walk
    /// to the next block.
    public static func parse(from data: Data) throws -> (block: LRIBlock, length: Int) {
        guard data.count >= headerSize else {
            throw LRIParseError.tooShort(context: "block header")
        }

        let base = data.startIndex
        guard Array(data[base..<(base + 4)]) == magic else {
            throw LRIParseError.badMagic
        }

        let blockLength = Int(data.readUInt64LE(at: base + 4))
        let messageOffset = Int(data.readUInt64LE(at: base + 12))
        let messageLength = Int(data.readUInt32LE(at: base + 20))
        let rawType = data[base + 24]

        guard let type = BlockType(rawValue: rawType) else {
            throw LRIParseError.unknownBlockType(rawType)
        }

        guard blockLength >= headerSize, data.count >= blockLength else {
            throw LRIParseError.tooShort(context: "block body (declared \(blockLength) bytes)")
        }

        let blockData = data.subdata(in: base..<(base + blockLength))
        let block = LRIBlock(
            type: type,
            messageOffset: messageOffset,
            messageLength: messageLength,
            data: blockData
        )
        return (block, blockLength)
    }
}

extension Data {
    func readUInt64LE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[offset + i]) << (8 * i)
        }
        return value
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[offset + i]) << (8 * i)
        }
        return value
    }
}
