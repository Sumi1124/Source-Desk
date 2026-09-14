import Foundation
import SQLite3

/// Minimal, dependency-free SQLite wrapper.
///
/// SourceDesk deliberately avoids third-party database packages: the app ships as
/// a self-contained Swift package, and SQLite (with FTS5 for keyword search) is
/// already on every Mac. Everything here is a thin, typed veneer over the C API.
public final class SQLiteDatabase: @unchecked Sendable {

    public enum OpenMode {
        case readWrite
        case readOnly
        case readWriteCreate
    }

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String, mode: OpenMode = .readWriteCreate) throws {
        self.path = path
        var flags: Int32
        switch mode {
        case .readWrite: flags = SQLITE_OPEN_READWRITE
        case .readOnly: flags = SQLITE_OPEN_READONLY
        case .readWriteCreate: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        flags |= SQLITE_OPEN_FULLMUTEX

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate database handle"
            if let db { sqlite3_close_v2(db) }
            throw SourceDeskError.database(message: "open \(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public var lastErrorMessage: String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    // MARK: - Execution

    /// Runs one or more statements with no result rows.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw SourceDeskError.database(message: "database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SourceDeskError.database(message: message)
        }
    }

    /// Convenience for statements with bound parameters.
    public func execute(_ sql: String, _ parameters: [SQLValue]) throws {
        _ = try query(sql, parameters, rowMapper: { _ in () })
    }

    public func query<T>(
        _ sql: String,
        _ parameters: [SQLValue] = [],
        rowMapper: (SQLiteRow) throws -> T
    ) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                results.append(try rowMapper(SQLiteRow(statement: statement)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SourceDeskError.database(message: "step failed: \(lastErrorMessage)")
            }
        }
        return results
    }

    public func queryOne<T>(
        _ sql: String,
        _ parameters: [SQLValue] = [],
        rowMapper: (SQLiteRow) throws -> T
    ) throws -> T? {
        try query(sql, parameters, rowMapper: rowMapper).first
    }

    public func scalarInt(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        try queryOne(sql, parameters) { $0.int(0) } ?? 0
    }

    public func scalarDouble(_ sql: String, _ parameters: [SQLValue] = []) throws -> Double {
        try queryOne(sql, parameters) { $0.double(0) } ?? 0
    }

    public func scalarString(_ sql: String, _ parameters: [SQLValue] = []) throws -> String? {
        let rows: [String?] = try query(sql, parameters) { $0.string(0) }
        return rows.first ?? nil
    }

    // MARK: - Transactions

    /// Runs `body` inside `BEGIN IMMEDIATE`, rolling back on any thrown error.
    /// Batches (a 5,000-chunk import, for example) go through this so a failure
    /// half-way through cannot leave a partially indexed source behind.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Statements

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw SourceDeskError.database(message: "database is closed") }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw SourceDeskError.database(message: "prepare failed: \(lastErrorMessage) — SQL: \(sql.prefix(200))")
        }
        return statement
    }

    private func bind(_ parameters: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .int(let v):
                rc = sqlite3_bind_int64(statement, index, v)
            case .double(let v):
                rc = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                rc = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                if v.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    rc = v.withUnsafeBytes { raw -> Int32 in
                        guard let base = raw.baseAddress else { return sqlite3_bind_null(statement, index) }
                        return sqlite3_bind_blob(statement, index, base, Int32(v.count), SQLITE_TRANSIENT)
                    }
                }
            }
            if rc != SQLITE_OK {
                throw SourceDeskError.database(message: "bind failed at index \(index): \(lastErrorMessage)")
            }
        }
    }

    /// Number of rows changed by the most recent statement.
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public var userVersion: Int32 {
        get { (try? Int32(scalarInt("PRAGMA user_version;"))) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue);") }
    }

    /// Runs SQLite's integrity check — used by Settings → Storage so users can
    /// verify their store without a separate tool.
    public func integrityCheck() throws -> String {
        try scalarString("PRAGMA integrity_check;") ?? "unknown"
    }
}

// MARK: - Values and rows

public enum SQLValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    public static func bool(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
    public static func date(_ v: Date?) -> SQLValue {
        guard let v else { return .null }
        return .double(v.timeIntervalSince1970)
    }
    public static func optionalText(_ v: String?) -> SQLValue {
        guard let v, !v.isEmpty else { return .null }
        return .text(v)
    }
}

public struct SQLiteRow {
    private let statement: OpaquePointer

    init(statement: OpaquePointer) {
        self.statement = statement
    }

    public var columnCount: Int { Int(sqlite3_column_count(statement)) }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func string(_ index: Int32) -> String? {
        guard !isNull(index), let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    public func nonEmptyString(_ index: Int32) -> String? {
        guard let value = string(index), !value.isEmpty else { return nil }
        return value
    }

    public func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    public func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func bool(_ index: Int32) -> Bool {
        isNull(index) ? false : sqlite3_column_int64(statement, index) != 0
    }

    public func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    public func date(_ index: Int32) -> Date? {
        guard !isNull(index) else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    public func nonOptionalDate(_ index: Int32) -> Date {
        date(index) ?? Date(timeIntervalSince1970: 0)
    }

    public func blob(_ index: Int32) -> Data? {
        guard !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    /// Floats are stored as little-endian Float32 blobs — compact and exact.
    public func floatVector(_ index: Int32) -> [Float] {
        guard let data = blob(index), !data.isEmpty else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            let count = raw.count / MemoryLayout<Float>.size
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                out[i] = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
            }
            return out
        }
    }
}

public enum FloatVectorCodec {
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Data() }
            return Data(bytes: base, count: buffer.count * MemoryLayout<Float>.size)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
