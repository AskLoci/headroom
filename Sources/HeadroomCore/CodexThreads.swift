import Foundation
import SQLite3

public struct CodexThread: Sendable, Equatable {
    public var id: String
    public var rolloutPath: String
    public var updatedAt: Date
    public var cwd: String
    public var title: String
    public var archived: Bool
    public var accountId: String?
}

public enum CodexThreadsError: Error {
    case open(String)
    case query(String)
}

/// Codex's thread index (`~/.codex/state_5.sqlite`, table `threads`), opened read-only.
public enum CodexThreads {
    /// User threads; subagent threads (a JSON `source` naming a subagent) are left out.
    public static func load(db url: URL) throws -> [CodexThread] {
        try withReadOnly(url) { db in
            let sql = """
                SELECT id, rollout_path, COALESCE(updated_at_ms, updated_at * 1000), cwd,
                       COALESCE(NULLIF(name, ''), NULLIF(title, ''), NULLIF(first_user_message, ''), preview, ''),
                       archived, creator_account_id
                FROM threads
                WHERE source NOT LIKE '{%subagent%'
                """
            var threads: [CodexThread] = []
            try query(db, sql) { row in
                threads.append(CodexThread(
                    id: text(row, 0) ?? "",
                    rolloutPath: text(row, 1) ?? "",
                    updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 2)) / 1000),
                    cwd: text(row, 3) ?? "",
                    title: TextCleaning.oneLine(text(row, 4) ?? "", max: 80),
                    archived: sqlite3_column_int(row, 5) != 0,
                    accountId: text(row, 6)
                ))
            }
            return threads
        }
    }

    /// Every account that created a thread on this Mac.
    public static func accountIds(db url: URL) throws -> [String] {
        try withReadOnly(url) { db in
            var ids: [String] = []
            let sql = "SELECT DISTINCT creator_account_id FROM threads WHERE creator_account_id IS NOT NULL AND creator_account_id <> '' ORDER BY 1"
            try query(db, sql) { row in
                if let id = text(row, 0) { ids.append(id) }
            }
            return ids
        }
    }

    /// Reads without writing to the database, its -wal or its -shm. While Codex has the database open, its
    /// newest commits are in the -wal; readonly_shm reads them without recording a read mark in the -shm.
    /// When Codex closes it, its SQLite checkpoints and deletes the -wal, which a read-only connection then
    /// fails to open (or creates); immutable reads the database file alone.
    static func withReadOnly<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let wal = FileManager.default.fileExists(atPath: url.fsPath + "-wal")
        let uri = "file:\(url.path(percentEncoded: true))?mode=ro&\(wal ? "readonly_shm=1" : "immutable=1")"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.fsPath)"
            sqlite3_close(handle)
            throw CodexThreadsError.open(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    static func query(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            throw CodexThreadsError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw CodexThreadsError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
