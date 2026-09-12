import Foundation

/// Where everything lives on disk.
///
/// Layout (the same layout a notebook export uses, which is why export is little
/// more than a zip of a notebook folder):
///
///     ~/Library/Application Support/SourceDesk/
///     ├── library.sqlite          notebooks, sources, chunks, embeddings, chat, notes
///     ├── content/<source-id>/    extracted text + original downloaded bytes
///     ├── cache/                  short-lived downloads, thumbnails
///     └── logs/                   rotating diagnostics
public struct AppPaths: Sendable {
    public let root: URL
    public let databaseURL: URL
    public let contentRoot: URL
    public let cacheRoot: URL
    public let logsRoot: URL
    public let exportsRoot: URL

    public init(root: URL) {
        self.root = root
        self.databaseURL = root.appendingPathComponent("library.sqlite")
        self.contentRoot = root.appendingPathComponent("content", isDirectory: true)
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        self.logsRoot = root.appendingPathComponent("logs", isDirectory: true)
        self.exportsRoot = root.appendingPathComponent("exports", isDirectory: true)
    }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SourceDesk", isDirectory: true)
    }

    public static func standard() -> AppPaths { AppPaths(root: defaultRoot) }

    public func createDirectories() throws {
        let fm = FileManager.default
        for url in [root, contentRoot, cacheRoot, logsRoot, exportsRoot] {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw SourceDeskError.storageUnavailable(path: url.path, reason: error.localizedDescription)
            }
        }
    }

    public func contentDirectory(for sourceID: RecordID) -> URL {
        contentRoot.appendingPathComponent(sourceID, isDirectory: true)
    }

    public func extractedTextURL(for sourceID: RecordID) -> URL {
        contentDirectory(for: sourceID).appendingPathComponent("content.txt")
    }

    public func originalFileURL(for sourceID: RecordID, fileName: String) -> URL {
        contentDirectory(for: sourceID).appendingPathComponent(fileName)
    }

    /// Renders a path with the home directory abbreviated, for display only.
    public func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Byte-level file helpers: read/write text, copy originals, hash, size.
public enum FileStore {

    public static func write(_ text: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw SourceDeskError.diskWriteFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SourceDeskError.diskWriteFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public static func readText(at url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url)
            if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
            if let latin = String(data: data, encoding: .isoLatin1) { return latin }
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: "Not valid UTF-8 or Latin-1 text.")
        } catch let error as SourceDeskError {
            throw error
        } catch {
            throw SourceDeskError.unreadableDocument(name: url.lastPathComponent, detail: error.localizedDescription)
        }
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// SHA-256 via CryptoKit, for content de-duplication and export manifests.
    public static func checksum(of data: Data) -> String {
        var hash = SHA256Shim()
        hash.update(data)
        return hash.finalize()
    }

    public static func checksum(ofFileAt url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        return checksum(of: data)
    }

    public static func totalSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

/// Tiny stand-in for CryptoKit's `SHA256` so the core target stays free of
/// platform-only frameworks. FNV-1a would be too weak for content addressing.
public struct SHA256Shim {
    // Implementation notes: this is a compact FIPS 180-4 SHA-256. It is used for
    // content de-duplication and export manifests only — no security claims.
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer = Data()
    private var totalBytes: UInt64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        totalBytes += UInt64(data.count)
        buffer.append(data)
        while buffer.count >= 64 {
            let block = buffer.prefix(64)
            buffer.removeFirst(64)
            process(Array(block))
        }
    }

    public mutating func finalize() -> String {
        var padding = Data([0x80])
        let remainder = (totalBytes + 1) % 64
        let padCount = remainder <= 56 ? 56 - Int(remainder) : 120 - Int(remainder)
        padding.append(Data(repeating: 0, count: padCount))
        let bits = totalBytes * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8((bits >> UInt64(shift)) & 0xff))
        }
        update(padding)
        let hex = state.map { String(format: "%08x", $0) }.joined()
        return hex
    }

    private mutating func process(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = (UInt32(block[i * 4]) << 24) | (UInt32(block[i * 4 + 1]) << 16)
                | (UInt32(block[i * 4 + 2]) << 8) | UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for i in 0..<64 {
            let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
