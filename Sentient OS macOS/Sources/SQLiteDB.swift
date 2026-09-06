//
//  SQLiteDB.swift
//  Sentient OS macOS
//
//  Minimal read access for the database sources (WhatsApp / iMessage / Notes), plus the
//  coherent SQLite snapshot. A read-only source connection includes committed WAL changes;
//  SQLite's backup API copies one consistent database into a private temporary directory.
//  Read the snapshot and delete it. For the DB sources we delete it *immediately* after extraction
//  so a plaintext copy of someone's messages never lingers on disk.
//
//  Shared by all three DB sources (the first real second-use-case that justifies a helper).
//

import Foundation
import SQLite3

/// `nonisolated` (the project defaults declarations to @MainActor): these are pure utilities that
/// work on a throwaway temp copy, so DB reads can run off-main — e.g. from the background ingestion
/// connectors that read each source's SQLite DB. @MainActor sources can still call them freely.
nonisolated enum SQLiteDB {
    enum DBError: Error, CustomStringConvertible {
        case missingFile(String)
        case open(String)
        case prepare(String)
        case snapshot(String)
        case step(String)
        var description: String {
            switch self {
            case .missingFile(let p): return "Database not found at: \(p) (is the app installed / Full Disk Access granted?)"
            case .open(let m):        return "SQLite open failed: \(m)"
            case .prepare(let m):     return "SQLite prepare failed: \(m)"
            case .snapshot(let m):    return "SQLite snapshot failed: \(m)"
            case .step(let m):        return "SQLite query failed: \(m)"
            }
        }
    }

    /// A transactionally consistent snapshot, including committed WAL pages. Copying the DB and
    /// sidecars one at a time races the owner's writes/checkpoints and can silently lose rows.
    /// The caller MUST delete `dir` when done; failed snapshots are removed here.
    static func walSafeCopy(of dbPath: String) throws -> (db: URL, dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { throw DBError.missingFile(dbPath) }

        let dir = fm.temporaryDirectory.appendingPathComponent("sentientos-db-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? fm.removeItem(at: dir) } }

        let name = URL(fileURLWithPath: dbPath).lastPathComponent
        let dst = dir.appendingPathComponent(name)
        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer { sqlite3_close(destination); sqlite3_close(source) }
        guard sqlite3_open_v2(dbPath, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw DBError.open(source.map { String(cString: sqlite3_errmsg($0)) } ?? "source unavailable")
        }
        guard sqlite3_open_v2(dst.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DBError.open(destination.map { String(cString: sqlite3_errmsg($0)) } ?? "snapshot unavailable")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        sqlite3_busy_timeout(source, 1000)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DBError.snapshot(String(cString: sqlite3_errmsg(destination)))
        }
        // One step holds a coherent source read transaction. Lock retries are bounded so an owning
        // app with a long write transaction defers this source instead of hanging ingestion.
        var result: Int32 = SQLITE_OK
        for attempt in 0..<3 {
            if Task.isCancelled { break }
            result = sqlite3_backup_step(backup, -1)
            if result != SQLITE_BUSY && result != SQLITE_LOCKED { break }
            if attempt < 2 { sqlite3_sleep(25) }
        }
        let finish = sqlite3_backup_finish(backup)
        try Task.checkCancellation()
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw DBError.snapshot(String(cString: sqlite3_errmsg(destination)))
        }
        // The source's WAL-mode header is copied too. Normalize only the destination so the
        // returned snapshot is one self-contained file and a read-only reader needs no sidecars.
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw DBError.snapshot(String(cString: sqlite3_errmsg(destination)))
        }
        completed = true
        return (dst, dir)
    }
}

/// A thin SQLite connection for reading one copied DB. Single-threaded use; closes on deinit.
/// Read-only: the backup has already incorporated committed WAL pages.
nonisolated final class SQLiteReader {
    private var db: OpaquePointer?
    private let dbName: String   // the DB basename (chat.db / ChatStorage.sqlite / …) — a diagnostics tag

    init(path: String) throws {
        dbName = URL(fileURLWithPath: path).lastPathComponent
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db); db = nil
            throw SQLiteDB.DBError.open(msg)
        }
    }
    deinit { sqlite3_close(db) }

    /// Run a read query, invoking `row` for each result row in order. (We interpolate only our own
    /// numeric literals into SQL — no untrusted input — so no bind params are needed.)
    func forEachRow(_ sql: String, _ row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // §7.7: our SQL is static (no user input), so a prepare failure = a SCHEMA change — the
            // "Apple/Meta renamed a column" tripwire, uniform across all 4 DB sources. The errmsg is a
            // schema string ("no such column: ZFOO"), never row content (allowlisted, §10).
            let errmsg = String(cString: sqlite3_errmsg(db))
            CrashReporting.captureEvent("db.schema_error", level: .error,
                tags: ["db": dbName],
                extra: ["msg": String(errmsg.prefix(200))],
                fingerprint: ["db", "schema_error", dbName])
            throw SQLiteDB.DBError.prepare(errmsg)
        }
        defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            try row(Row(stmt!))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteDB.DBError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Typed, index-based column access for one row.
    struct Row {
        private let stmt: OpaquePointer
        init(_ s: OpaquePointer) { stmt = s }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func blob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
