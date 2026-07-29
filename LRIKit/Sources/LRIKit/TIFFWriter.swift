import Foundation

/// A minimal, uncompressed little-endian TIFF/IFD writer -- just enough to
/// build valid DNG files (baseline TIFF tags + a handful of DNG-specific
/// ones). Not a general-purpose TIFF library.
struct TIFFWriter {
    enum FieldType: UInt16 {
        case byte = 1
        case ascii = 2
        case short = 3
        case long = 4
        case rational = 5
        case sbyte = 6
        case sshort = 8
        case slong = 9
        case srational = 10

        var elementSize: Int {
            switch self {
            case .byte, .ascii, .sbyte: 1
            case .short, .sshort: 2
            case .long, .slong: 4
            case .rational, .srational: 8
            }
        }
    }

    struct Entry {
        let tag: UInt16
        let type: FieldType
        let count: Int
        /// Exactly `count * type.elementSize` bytes, already little-endian encoded.
        let value: Data
    }

    private var entries: [Entry] = []
    /// Data appended after the pixel strip, referenced by entries that don't fit inline.
    private var trailingData: [(entryIndex: Int, data: Data)] = []

    mutating func add(tag: UInt16, short value: UInt16) {
        entries.append(Entry(tag: tag, type: .short, count: 1, value: le16(value)))
    }

    mutating func add(tag: UInt16, long value: UInt32) {
        entries.append(Entry(tag: tag, type: .long, count: 1, value: le32(value)))
    }

    mutating func add(tag: UInt16, shorts values: [UInt16]) {
        var data = Data()
        for v in values { data.append(le16(v)) }
        entries.append(Entry(tag: tag, type: .short, count: values.count, value: data))
    }

    mutating func add(tag: UInt16, bytes values: [UInt8]) {
        entries.append(Entry(tag: tag, type: .byte, count: values.count, value: Data(values)))
    }

    mutating func add(tag: UInt16, ascii string: String) {
        var data = Data(string.utf8)
        data.append(0) // NUL-terminated, included in count
        entries.append(Entry(tag: tag, type: .ascii, count: data.count, value: data))
    }

    /// Each element is (numerator, denominator).
    mutating func add(tag: UInt16, rationals values: [(UInt32, UInt32)]) {
        var data = Data()
        for (n, d) in values {
            data.append(le32(n))
            data.append(le32(d))
        }
        entries.append(Entry(tag: tag, type: .rational, count: values.count, value: data))
    }

    /// Each element is (numerator, denominator).
    mutating func add(tag: UInt16, srationals values: [(Int32, Int32)]) {
        var data = Data()
        for (n, d) in values {
            data.append(le32(UInt32(bitPattern: n)))
            data.append(le32(UInt32(bitPattern: d)))
        }
        entries.append(Entry(tag: tag, type: .srational, count: values.count, value: data))
    }

    /// Assembles the full file. `stripData` is appended after the IFD and
    /// any overflow tag data; `stripOffsetTag`'s value is patched in once
    /// the strip's absolute offset is known.
    func build(stripOffsetTag: UInt16, stripData: Data) -> Data {
        // Sorted by tag, as TIFF requires ascending tag order within an IFD.
        let sorted = entries.enumerated().sorted { $0.element.tag < $1.element.tag }

        let headerSize = 8
        let ifdCountSize = 2
        let entrySize = 12
        let ifdEntriesSize = sorted.count * entrySize
        let nextIFDOffsetSize = 4
        let ifdEnd = headerSize + ifdCountSize + ifdEntriesSize + nextIFDOffsetSize

        var overflowOffsets: [Int: Int] = [:] // original entry index -> absolute file offset
        var cursor = ifdEnd
        for (originalIndex, entry) in sorted.map({ ($0.offset, $0.element) }) {
            if entry.value.count > 4 {
                overflowOffsets[originalIndex] = cursor
                cursor += entry.value.count
                if cursor % 2 == 1 { cursor += 1 } // word-align, as TIFF requires
            }
        }
        let stripOffset = cursor

        var file = Data()
        file.append(contentsOf: [0x49, 0x49]) // "II" little-endian
        file.append(le16(42))
        file.append(le32(UInt32(headerSize)))

        file.append(le16(UInt16(sorted.count)))
        for (originalIndex, entry) in sorted.map({ ($0.offset, $0.element) }) {
            file.append(le16(entry.tag))
            file.append(le16(entry.type.rawValue))
            file.append(le32(UInt32(entry.count)))

            if entry.tag == stripOffsetTag {
                file.append(le32(UInt32(stripOffset)))
            } else if entry.value.count <= 4 {
                var inline = entry.value
                while inline.count < 4 { inline.append(0) }
                file.append(inline)
            } else {
                file.append(le32(UInt32(overflowOffsets[originalIndex]!)))
            }
        }
        file.append(le32(0)) // no next IFD

        for entry in sorted.map(\.element) {
            guard entry.value.count > 4 else { continue }
            file.append(entry.value)
            if file.count % 2 == 1 { file.append(0) }
        }

        assert(file.count == stripOffset, "TIFF layout arithmetic drifted: \(file.count) != \(stripOffset)")
        file.append(stripData)

        return file
    }
}

private func le16(_ v: UInt16) -> Data {
    Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
}

private func le32(_ v: UInt32) -> Data {
    Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
}
