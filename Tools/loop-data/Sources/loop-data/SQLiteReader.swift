import Foundation
import SQLite3

/// SQLite's own sentinel for "copy the bound string" — the C macro isn't imported into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal READ-ONLY SQLite handle. Opens with `SQLITE_OPEN_READONLY` so it can never write,
/// checkpoint, or grow the `-wal` — safe to run against the store while the Loop app has it open.
/// Column values come back as Int64 / Double / String / NSNull, ready to drop into JSONSerialization.
final class SQLiteReader {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError("database not found at \(path)\n" +
                           "Pass --db <path>, or open the Loop app once so it creates its store.")
        }
        // Read-only: no writes, no WAL checkpoint. `nomutex` is fine — we never share the handle.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CLIError("could not open \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 3000) // the app may hold a write lock mid-transaction; wait it out
    }

    deinit { sqlite3_close(db) }

    /// Run a query with positional `?` parameters (Int64 / Int / Double / String only) and return
    /// every row as an ordered-key dictionary. NULLs come back as `NSNull()`.
    func rows(_ sql: String, _ params: [Any] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CLIError("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as Int64:  sqlite3_bind_int64(stmt, idx, v)
            case let v as Int:    sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default:              sqlite3_bind_null(stmt, idx)
            }
        }

        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT:    row[name] = String(cString: sqlite3_column_text(stmt, c))
                default:             row[name] = NSNull()
                }
            }
            out.append(row)
        }
        return out
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}
