import Foundation
import CSQLite

/// Minimal SQLite wrapper — enough for the listing cache and transfer history,
/// with no dependency to fetch or keep up to date.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(db)
            throw StorageError.provider("Couldn't open the cache database: \(message)")
        }
        self.handle = db

        // WAL plus a relaxed sync: this is a cache, so a power loss losing the
        // last write is fine, and it keeps writes off the UI's critical path.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA busy_timeout = 3000")
        try execute("PRAGMA temp_store = MEMORY")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw StorageError.provider("The cache database is closed.") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw StorageError.provider("Cache query failed: \(message)")
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        guard let handle else { throw StorageError.provider("The cache database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw StorageError.provider("Couldn't prepare a cache query: \(message)")
        }
        return Statement(statement, db: handle)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    final class Statement {
        private let statement: OpaquePointer
        private let db: OpaquePointer

        init(_ statement: OpaquePointer, db: OpaquePointer) {
            self.statement = statement
            self.db = db
        }

        deinit { sqlite3_finalize(statement) }

        @discardableResult
        func bind(_ index: Int32, _ value: String) -> Statement {
            // SQLITE_TRANSIENT: let SQLite copy, since the Swift string's buffer
            // isn't guaranteed to outlive the call.
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT_SHIM)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Int64) -> Statement {
            sqlite3_bind_int64(statement, index, value)
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Data) -> Statement {
            _ = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement, index, buffer.baseAddress,
                    Int32(buffer.count), SQLITE_TRANSIENT_SHIM
                )
            }
            return self
        }

        /// Runs a statement that returns no rows.
        func run() throws {
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE || code == SQLITE_ROW else {
                throw StorageError.provider("Cache write failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        /// Steps to the next row, returning false when the result set is done.
        func step() -> Bool {
            sqlite3_step(statement) == SQLITE_ROW
        }

        func reset() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func int64(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func blob(_ column: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0 else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }
}

/// `SQLITE_TRANSIENT` is a cast of -1 to a function pointer; Swift can't import
/// the C macro, so it's reconstructed here.
private let SQLITE_TRANSIENT_SHIM = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
