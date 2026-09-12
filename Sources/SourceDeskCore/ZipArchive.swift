import Foundation
import CZlib

/// A small ZIP reader/writer.
///
/// SourceDesk's export format is a plain `.nbk` zip so a notebook stays readable
/// with `unzip` and any text editor — no lock-in, no proprietary container. Only
/// the two methods every unzip tool supports are produced: *deflate* for text and
/// *store* for already-compressed payloads (PDF originals).
public enum ZipCompression: Sendable {
    case store
    case deflate
}

// MARK: - Writing

public struct ZipWriter {

    public struct Entry {
        public var path: String
        public var data: Data
        public var compression: ZipCompression
        public var modified: Date

        public init(path: String, data: Data, compression: ZipCompression = .deflate, modified: Date = Date()) {
            self.path = path
            self.data = data
            self.compression = compression
            self.modified = modified
        }

        public init(path: String, text: String, compression: ZipCompression = .deflate) {
            self.init(path: path, data: Data(text.utf8), compression: compression)
        }
    }

    private struct CentralRecord {
        var path: String
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var offset: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private var body = Data()
    private var central: [CentralRecord] = []

    public init() {}

    public var entryCount: Int { central.count }

    public mutating func add(_ entry: Entry) throws {
        let payload = entry.data
        let crc = UInt32(truncatingIfNeeded: CZlib.crc32(0, [UInt8](payload), uInt(payload.count)))
        let (method, compressed): (UInt16, Data)
        switch entry.compression {
        case .store:
            (method, compressed) = (0, payload)
        case .deflate:
            // Tiny entries gain nothing from deflate and some tools dislike
            // zero-length deflate streams, so they are stored.
            if payload.count < 64 {
                (method, compressed) = (0, payload)
            } else {
                (method, compressed) = (8, try Deflate.compress(payload))
            }
        }
        let (time, date) = Self.dosTimestamp(entry.modified)
        let nameBytes = Array(entry.path.utf8)
        guard nameBytes.count < Int(UInt16.max) else {
            throw SourceDeskError.diskWriteFailed(path: entry.path, reason: "Archive entry path is too long.")
        }

        let offset = UInt32(body.count)
        body.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])               // local file header
        body.appendLE(UInt16(20))                                       // version needed
        body.appendLE(UInt16(1 << 11))                                  // UTF-8 names
        body.appendLE(method)
        body.appendLE(time)
        body.appendLE(date)
        body.appendLE(crc)
        body.appendLE(UInt32(compressed.count))
        body.appendLE(UInt32(payload.count))
        body.appendLE(UInt16(nameBytes.count))
        body.appendLE(UInt16(0))                                        // extra length
        body.append(contentsOf: nameBytes)
        body.append(compressed)

        central.append(CentralRecord(
            path: entry.path, crc: crc, compressedSize: UInt32(compressed.count),
            uncompressedSize: UInt32(payload.count), method: method, offset: offset,
            dosTime: time, dosDate: date
        ))
    }

    public mutating func addText(_ path: String, _ text: String) throws {
        try add(Entry(path: path, text: text))
    }

    public mutating func addJSON<T: Encodable>(_ path: String, _ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try add(Entry(path: path, data: try encoder.encode(value)))
    }

    public func finalize() -> Data {
        var archive = body
        let centralStart = UInt32(archive.count)
        for record in central {
            let nameBytes = Array(record.path.utf8)
            archive.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])        // central directory header
            archive.appendLE(UInt16(20))                                // version made by
            archive.appendLE(UInt16(20))                                // version needed
            archive.appendLE(UInt16(1 << 11))                           // UTF-8
            archive.appendLE(record.method)
            archive.appendLE(record.dosTime)
            archive.appendLE(record.dosDate)
            archive.appendLE(record.crc)
            archive.appendLE(record.compressedSize)
            archive.appendLE(record.uncompressedSize)
            archive.appendLE(UInt16(nameBytes.count))
            archive.appendLE(UInt16(0))                                 // extra
            archive.appendLE(UInt16(0))                                 // comment
            archive.appendLE(UInt16(0))                                 // disk number
            archive.appendLE(UInt16(0))                                 // internal attributes
            archive.appendLE(UInt32(0x81a4 << 16))                      // external: -rw-r--r--
            archive.appendLE(record.offset)
            archive.append(contentsOf: nameBytes)
        }
        let centralSize = UInt32(archive.count) - centralStart
        archive.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])            // end of central directory
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(central.count))
        archive.appendLE(UInt16(central.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralStart)
        archive.appendLE(UInt16(0))                                     // comment length
        return archive
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        let hour = UInt16(parts.hour ?? 0)
        let minute = UInt16(parts.minute ?? 0)
        let second = UInt16((parts.second ?? 0) / 2)
        let time: UInt16 = (hour << 11) | (minute << 5) | second
        let yearBits = UInt16((year - 1980) << 9)
        let monthBits = UInt16((parts.month ?? 1) << 5)
        let dayBits = UInt16(parts.day ?? 1)
        let day: UInt16 = yearBits | monthBits | dayBits
        return (time, day)
    }
}

// MARK: - Reading

/// Reads the *central directory* rather than scanning local headers, which is what
/// makes imports robust for archives written by other tools (different ordering,
/// data descriptors, ZIP64 fields on small entries, and so on).
public struct ZipArchive {

    public struct Entry {
        public var path: String
        public var uncompressedSize: Int
        public var compressedSize: Int
        public var method: UInt16
        public var localHeaderOffset: Int
    }

    private let data: Data
    public private(set) var entries: [Entry] = []

    public init(data: Data) throws {
        self.data = data
        guard let eocd = Self.findEndOfCentralDirectory(in: data) else {
            throw SourceDeskError.archiveCorrupt(detail: "End-of-central-directory record not found.")
        }
        let entryCount = Int(data.readLE16(at: eocd + 10))
        let centralOffset = Int(data.readLE32(at: eocd + 16))
        guard centralOffset >= 0, centralOffset < data.count else {
            throw SourceDeskError.archiveCorrupt(detail: "Central directory offset is out of range.")
        }
        var cursor = centralOffset
        var collected: [Entry] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, data.readLE32(at: cursor) == 0x02014b50 else {
                throw SourceDeskError.archiveCorrupt(detail: "Malformed central directory entry at \(cursor).")
            }
            let method = data.readLE16(at: cursor + 10)
            let compressedSize = Int(data.readLE32(at: cursor + 20))
            let uncompressedSize = Int(data.readLE32(at: cursor + 24))
            let nameLength = Int(data.readLE16(at: cursor + 28))
            let extraLength = Int(data.readLE16(at: cursor + 30))
            let commentLength = Int(data.readLE16(at: cursor + 32))
            let localOffset = Int(data.readLE32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw SourceDeskError.archiveCorrupt(detail: "Entry name runs past the end of the archive.")
            }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            collected.append(Entry(
                path: name, uncompressedSize: uncompressedSize, compressedSize: compressedSize,
                method: method, localHeaderOffset: localOffset
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = collected
    }

    public init(fileAt url: URL) throws {
        do {
            try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw SourceDeskError.archiveCorrupt(detail: error.localizedDescription)
        }
    }

    public var paths: [String] { entries.map(\.path) }

    public func contains(_ path: String) -> Bool { entries.contains { $0.path == path } }

    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    public func data(for path: String) throws -> Data {
        guard let entry = entry(path) else {
            throw SourceDeskError.notFound(entity: "archive entry", id: path)
        }
        return try read(entry)
    }

    public func text(for path: String) throws -> String {
        String(decoding: try data(for: path), as: UTF8.self)
    }

    public func read(_ entry: Entry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count, data.readLE32(at: offset) == 0x04034b50 else {
            throw SourceDeskError.archiveCorrupt(detail: "Bad local header for \(entry.path).")
        }
        let nameLength = Int(data.readLE16(at: offset + 26))
        let extraLength = Int(data.readLE16(at: offset + 28))
        let payloadStart = offset + 30 + nameLength + extraLength
        let size = entry.compressedSize
        guard payloadStart + size <= data.count else {
            throw SourceDeskError.archiveCorrupt(detail: "Payload for \(entry.path) is truncated.")
        }
        let payload = Data(data[payloadStart..<(payloadStart + size)])
        switch entry.method {
        case 0:
            return payload
        case 8:
            do {
                return try Deflate.decompress(payload, expectedSize: entry.uncompressedSize)
            } catch {
                throw SourceDeskError.archiveCorrupt(detail: "Could not inflate \(entry.path): \(error.localizedDescription)")
            }
        default:
            throw SourceDeskError.archiveCorrupt(
                detail: "\(entry.path) uses compression method \(entry.method), which SourceDesk does not read. Re-export it as a standard deflate zip."
            )
        }
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minimum = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= minimum {
            if data.readLE32(at: index) == 0x06054b50 { return index }
            index -= 1
        }
        return nil
    }
}

// MARK: - zlib raw deflate

enum Deflate {

    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        let initResult = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                       zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw SourceDeskError.diskWriteFailed(path: "archive", reason: "deflate init failed (\(initResult)).")
        }
        defer { deflateEnd(&stream) }

        let chunkSize = 128 * 1024
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            var remaining = uInt(input.count)
            repeat {
                let limit = min(remaining, uInt(Int32.max))
                stream.avail_in = limit
                repeat {
                    let produced: Int = buffer.withUnsafeMutableBytes { out in
                        stream.next_out = out.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        stream.avail_out = uInt(chunkSize)
                        let rc = zlib.deflate(&stream, Z_NO_FLUSH)
                        if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR {
                            return -1
                        }
                        return chunkSize - Int(stream.avail_out)
                    }
                    if produced < 0 { throw SourceDeskError.diskWriteFailed(path: "archive", reason: "deflate failed.") }
                    if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                } while stream.avail_out == 0
                remaining -= limit
                stream.next_in = stream.next_in.map { $0 } // advance handled by zlib
            } while remaining > 0
        }

        var produced: Int
        repeat {
            let capacity = buffer.count
            produced = buffer.withUnsafeMutableBytes { out in
                stream.next_out = out.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(capacity)
                let rc = zlib.deflate(&stream, Z_FINISH)
                if rc != Z_OK && rc != Z_STREAM_END { return -1 }
                return capacity - Int(stream.avail_out)
            }
            if produced < 0 { throw SourceDeskError.diskWriteFailed(path: "archive", reason: "deflate finish failed.") }
            if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
        } while produced > 0
        return output
    }

    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw SourceDeskError.archiveCorrupt(detail: "inflate init failed (\(initResult)).")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let capacity = expectedSize > 0 ? expectedSize : max(input.count * 4, 4096)
        output.reserveCapacity(capacity)

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            while true {
                let produced: Int = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    stream.avail_out = uInt(chunkSize)
                    let rc = zlib.inflate(&stream, Z_NO_FLUSH)
                    if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR { return -1 }
                    return chunkSize - Int(stream.avail_out)
                }
                if produced < 0 { throw SourceDeskError.archiveCorrupt(detail: "inflate returned an error.") }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if stream.avail_in == 0 && produced == 0 { break }
                if stream.avail_in == 0 && Int(stream.avail_out) == chunkSize { break }
            }
        }
        return output
    }
}

// MARK: - Little-endian helpers

extension Data {
    func readLE16(at index: Int) -> UInt16 {
        guard index + 2 <= count else { return 0 }
        return UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }

    func readLE32(at index: Int) -> UInt32 {
        guard index + 4 <= count else { return 0 }
        return UInt32(self[index]) | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16) | (UInt32(self[index + 3]) << 24)
    }

    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
