// Transactional local evidence and source permissions. Failed opens/writes never reset existing data.
import Foundation
import SQLite3

nonisolated struct StoredEvidence: Sendable, Identifiable {
    var source: ImportSource
    var record: EvidenceRecord
    var id: String { EvidenceIdentity.digest(source.id + "\u{0}" + record.id) }
}

nonisolated struct ImportStatus: Codable, Sendable {
    var state: String = "idle"
    var message: String = "Ready to import"
    var files: Int = 0
    var records: Int = 0
    var attemptedAt: Date? = nil
}

/// One recursive lock serializes this connection. SQLite transactions serialize other app processes.
/// No public operation holds a transaction while running an adapter or awaiting a model.
nonisolated final class EvidenceStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    let url: URL

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default, parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let existed = fm.fileExists(atPath: url.path)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw ContextError.database("Could not open the local context database. Check folder access and free disk space; existing data has been preserved.")
        }
        do {
            if !existed { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            sqlite3_busy_timeout(db, 5_000)
            let version = Int(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
            guard version <= 2 else { throw ContextError.database("This context database needs a newer Sentient version. Existing data has been preserved.") }
            if version == 0 {
                guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").isEmpty else {
                    throw ContextError.database("Unrecognized context database schema. Existing data has been preserved.")
                }
            }
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE sources (id TEXT PRIMARY KEY, payload TEXT NOT NULL, status TEXT)")
                    try execute("CREATE TABLE records (source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, record_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(source_id,record_id))")
                    try execute("CREATE TABLE owners (source_id TEXT NOT NULL, file_id TEXT NOT NULL, document_id TEXT NOT NULL, record_id TEXT NOT NULL, payload TEXT NOT NULL, snapshot REAL NOT NULL, PRIMARY KEY(source_id,file_id,document_id,record_id), FOREIGN KEY(source_id,record_id) REFERENCES records(source_id,record_id) ON DELETE CASCADE)")
                    try execute("CREATE TABLE imports (source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE, file_id TEXT NOT NULL, fingerprint TEXT NOT NULL, complete INTEGER NOT NULL, PRIMARY KEY(source_id,file_id))")
                    try execute("PRAGMA user_version=2")
                }
            } else if version == 1 {
                try transaction {
                    try execute("ALTER TABLE owners ADD COLUMN payload TEXT")
                    try execute("ALTER TABLE owners ADD COLUMN snapshot REAL NOT NULL DEFAULT 0")
                    try execute("UPDATE owners SET payload=(SELECT payload FROM records WHERE records.source_id=owners.source_id AND records.record_id=owners.record_id)")
                    // v1 retained only the winning payload. Keep it until each original can be reread.
                    try execute("UPDATE imports SET complete=0")
                    try execute("PRAGMA user_version=2")
                }
            }
            if !existed { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    func sources() throws -> [ImportSource] {
        try lock.withLock { try rows("SELECT payload FROM sources ORDER BY id").map { try decode(ImportSource.self, $0[0]) } }
    }
    func source(_ id: String) throws -> ImportSource? {
        try lock.withLock { try rows("SELECT payload FROM sources WHERE id=?", [id]).first.map { try decode(ImportSource.self, $0[0]) } }
    }
    func saveSource(_ value: ImportSource) throws {
        try lock.withLock {
          try transaction {
            guard value.path.hasPrefix("/"), !value.id.isEmpty else { throw ContextError.invalid("Choose an absolute source path.") }
            let canonical = URL(fileURLWithPath: value.path).standardizedFileURL.path
            guard try !sources().contains(where: { $0.id != value.id && $0.kind == value.kind && URL(fileURLWithPath: $0.path).standardizedFileURL.path == canonical }) else {
                throw ContextError.invalid("This source is already configured. Use its Import or Retry button.")
            }
            let old = try source(value.id)
            try execute("INSERT INTO sources(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [value.id, try encode(value)])
            if let old, old.project != value.project || old.path != value.path || old.kind != value.kind {
                try execute("UPDATE imports SET complete=0 WHERE source_id=?", [value.id])
            }
          }
        }
    }
    func removeSource(_ id: String) throws {
        try lock.withLock { try execute("DELETE FROM sources WHERE id=?", [id]) }
    }
    func setStatus(_ status: ImportStatus, sourceID: String) throws {
        try lock.withLock { try execute("UPDATE sources SET status=? WHERE id=?", [try encode(status), sourceID]) }
    }
    func status(_ sourceID: String) throws -> ImportStatus {
        try lock.withLock {
            let value = try rows("SELECT COALESCE(status,'') FROM sources WHERE id=?", [sourceID]).first?.first ?? ""
            return value.isEmpty ? ImportStatus() : try decode(ImportStatus.self, value)
        }
    }
    func isCurrent(sourceID: String, fileID: String, fingerprint: String) throws -> Bool {
        try lock.withLock { try rows("SELECT 1 FROM imports WHERE source_id=? AND file_id=? AND fingerprint=? AND complete=1", [sourceID, fileID, fingerprint]).count == 1 }
    }

    /// Commit accepted records and their fingerprint together. Partial parses preserve the old tail.
    func commit(sourceID: String, fileID: String, fingerprint: String, documents: [ImportDocument], expectedSource: ImportSource? = nil, snapshotDate: Date = Date()) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard Set(documents.map(\.id)).count == documents.count else { throw ContextError.invalid("Duplicate document identities in one source file.") }
            guard documents.reduce(0, { $0 + $1.records.count }) <= 200_000 else { throw ContextError.limit("Too many records in one file. Export smaller sessions.") }
            try transaction {
                guard let source = try source(sourceID), source.enabled else {
                    throw ContextError.unavailable("Collection stopped or this source was removed. No new records were saved.")
                }
                if let expectedSource, source != expectedSource { throw ContextError.unavailable("Source settings changed during import. No checkpoint was advanced; retry using current settings.") }
                var changedIDs = Set(try rows("SELECT record_id FROM owners WHERE source_id=? AND file_id=?", [sourceID, fileID]).map { $0[0] })
                let full = documents.allSatisfy(\.complete)
                let replaces = documents.allSatisfy(\.replaceExisting)
                if full && replaces {
                    let keep = Set(documents.map(\.id))
                    for old in try rows("SELECT DISTINCT document_id FROM owners WHERE source_id=? AND file_id=?", [sourceID, fileID]) where !keep.contains(old[0]) {
                        try execute("DELETE FROM owners WHERE source_id=? AND file_id=? AND document_id=?", [sourceID, fileID, old[0]])
                    }
                }
                for document in documents {
                    try Task.checkCancellation()
                    guard Set(document.records.map(\.id)).count == document.records.count else {
                        throw ContextError.invalid("A source document contains duplicate record identities. No checkpoint was advanced.")
                    }
                    if document.complete && document.replaceExisting {
                        let retainedIDs = Set(document.records.map(\.id))
                        for row in try rows("SELECT record_id FROM owners WHERE source_id=? AND file_id=? AND document_id=?", [sourceID, fileID, document.id]) where !retainedIDs.contains(row[0]) {
                            try execute("DELETE FROM owners WHERE source_id=? AND file_id=? AND document_id=? AND record_id=?", [sourceID, fileID, document.id, row[0]])
                        }
                    }
                    for input in document.records {
                        try Task.checkCancellation()
                        guard input.id.utf8.count <= 2_048, !input.id.isEmpty else { throw ContextError.invalid("Invalid or oversized source record identity.") }
                        changedIDs.insert(input.id)
                        guard var record = EvidencePrivacy.sanitize(input) else {
                            try execute("DELETE FROM owners WHERE source_id=? AND file_id=? AND document_id=? AND record_id=?", [sourceID, fileID, document.id, input.id])
                            continue
                        }
                        if record.project == nil { record.project = source.project }
                        if let oldJSON = try rows("SELECT payload FROM records WHERE source_id=? AND record_id=?", [sourceID, record.id]).first?.first {
                            let old = try decode(EvidenceRecord.self, oldJSON)
                            if !Self.isOlder(record, than: old) {
                                try execute("UPDATE records SET payload=? WHERE source_id=? AND record_id=?", [try encode(record), sourceID, record.id])
                            }
                        } else {
                            try execute("INSERT INTO records(source_id,record_id,payload) VALUES(?,?,?)", [sourceID, record.id, try encode(record)])
                        }
                        if let oldJSON = try rows("SELECT payload FROM owners WHERE source_id=? AND file_id=? AND document_id=? AND record_id=?", [sourceID, fileID, document.id, record.id]).first?.first,
                           Self.isOlder(record, than: try decode(EvidenceRecord.self, oldJSON)) { continue }
                        try execute("INSERT INTO owners(source_id,file_id,document_id,record_id,payload,snapshot) VALUES(?,?,?,?,?,?) ON CONFLICT(source_id,file_id,document_id,record_id) DO UPDATE SET payload=excluded.payload,snapshot=excluded.snapshot", [sourceID, fileID, document.id, record.id, try encode(record), String(snapshotDate.timeIntervalSince1970)])
                    }
                }
                try refreshRecords(sourceID, ids: changedIDs)
                try Task.checkCancellation()
                try execute("INSERT INTO imports(source_id,file_id,fingerprint,complete) VALUES(?,?,?,?) ON CONFLICT(source_id,file_id) DO UPDATE SET fingerprint=excluded.fingerprint,complete=excluded.complete", [sourceID, fileID, fingerprint, full ? "1" : "0"])
            }
        }
    }

    /// Only call after a successful complete directory census, never after access/listing failures.
    func reconcileFiles(sourceID: String, retaining files: Set<String>, expectedSource: ImportSource? = nil) throws {
        try lock.withLock {
            try transaction {
                guard let source = try source(sourceID), source.enabled else { throw ContextError.unavailable("Collection has stopped.") }
                if let expectedSource, source != expectedSource { throw ContextError.unavailable("Source settings changed. Existing records were preserved; retry using current settings.") }
                var changedIDs = Set<String>()
                for row in try rows("SELECT file_id FROM imports WHERE source_id=?", [sourceID]) where !files.contains(row[0]) {
                    changedIDs.formUnion(try rows("SELECT record_id FROM owners WHERE source_id=? AND file_id=?", [sourceID, row[0]]).map { $0[0] })
                    try execute("DELETE FROM owners WHERE source_id=? AND file_id=?", [sourceID, row[0]])
                    try execute("DELETE FROM imports WHERE source_id=? AND file_id=?", [sourceID, row[0]])
                }
                try refreshRecords(sourceID, ids: changedIDs)
            }
        }
    }

    func evidence(audience: ContextAudience, sourceIDs: Set<String> = [], project: String? = nil,
                  after: Date? = nil, before: Date? = nil, limit: Int = 100_000) throws -> [StoredEvidence] {
        try lock.withLock {
          try execute("BEGIN")
          do {
            var result: [StoredEvidence] = []
            var payloadBytes = 0
            for source in try sources() where source.contextEnabled && (audience == .local || source.shareEnabled) && (sourceIDs.isEmpty || sourceIDs.contains(source.id)) {
                var sql = "SELECT payload FROM records WHERE source_id=? AND json_extract(payload,'$.deleted')=0"
                var args = [source.id]
                if let project, !project.hasPrefix("project:") { sql += " AND json_extract(payload,'$.project')=?"; args.append(project) }
                // Stream payloads so a large database does not allocate all rows before applying limits.
                let statement = try prepare(sql + " ORDER BY record_id", args)
                defer { sqlite3_finalize(statement) }
                var code = sqlite3_step(statement)
                while code == SQLITE_ROW {
                    try Task.checkCancellation()
                    let text = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                    let record = try decode(EvidenceRecord.self, text)
                    let date = (after != nil || before != nil) ? record.occurredAt : nil
                    let matchesProject = project?.hasPrefix("project:") != true || record.project.map { EvidenceIdentity.projectKey(sourceID: source.id, project: $0) == project } == true
                    if matchesProject && (after == nil || date.map { $0 >= after! } == true) && (before == nil || date.map { $0 <= before! } == true) {
                        guard result.count < limit else { throw ContextError.limit("This query exceeds \(limit) records. Select a project, source, or narrower time range.") }
                        payloadBytes += text.utf8.count
                        guard payloadBytes <= 67_108_864 else { throw ContextError.limit("Context exceeds 64 MiB of evidence. Narrow the project, source or time filters.") }
                        result.append(StoredEvidence(source: source, record: record))
                    }
                    code = sqlite3_step(statement)
                }
                guard code == SQLITE_DONE else { throw ContextError.database("Context read failed (SQLite \(code)). No partial result was accepted.") }
            }
            try execute("COMMIT")
            return result
          } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    func counts(sourceID: String) throws -> Int {
        try lock.withLock {
            Int(try rows("SELECT COUNT(*) FROM records WHERE source_id=? AND json_extract(payload,'$.deleted')=0", [sourceID]).first?.first ?? "0") ?? 0
        }
    }

    /// Metadata-only catalog paging: never materializes transcript bodies just to find project IDs.
    func projects(sourceID: String, audience: ContextAudience, offset: Int = 0, limit: Int = 9) throws -> [String] {
        try lock.withLock {
            guard let source = try source(sourceID), source.contextEnabled, audience == .local || source.shareEnabled else { return [] }
            return try rows("SELECT DISTINCT json_extract(payload,'$.project') FROM records WHERE source_id=? AND json_extract(payload,'$.deleted')=0 AND json_extract(payload,'$.project') IS NOT NULL ORDER BY 1 LIMIT ? OFFSET ?", [sourceID, String(limit), String(offset)]).map { $0[0] }
        }
    }

    func evidence(citation: ContextCitation, audience: ContextAudience) throws -> StoredEvidence? {
        try lock.withLock {
            try execute("BEGIN")
            do {
                var found: StoredEvidence?
                if let source = try source(citation.sourceID), source.contextEnabled, audience == .local || source.shareEnabled,
                   let text = try rows("SELECT payload FROM records WHERE source_id=? AND record_id=?", [source.id, citation.recordID]).first?.first {
                    let record = try decode(EvidenceRecord.self, text)
                    let item = StoredEvidence(source: source, record: record)
                    if !record.deleted && item.id == citation.id { found = item }
                }
                try execute("COMMIT"); return found
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    func evidence(idPrefix: String, audience: ContextAudience) throws -> StoredEvidence? {
        try lock.withLock {
            try execute("BEGIN")
            do {
                var found: StoredEvidence?
                for source in try sources() where source.contextEnabled && (audience == .local || source.shareEnabled) {
                    let statement = try prepare("SELECT record_id FROM records WHERE source_id=?", [source.id])
                    defer { sqlite3_finalize(statement) }
                    var code = sqlite3_step(statement), scanned = 0
                    while code == SQLITE_ROW {
                        try Task.checkCancellation(); scanned += 1
                        guard scanned <= 1_000_000 else { throw ContextError.limit("Citation lookup exceeds one million record IDs. Narrow the included sources.") }
                        let native = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                        if EvidenceIdentity.digest(source.id + "\u{0}" + native).hasPrefix(idPrefix),
                           let text = try rows("SELECT payload FROM records WHERE source_id=? AND record_id=?", [source.id, native]).first?.first {
                            let record = try decode(EvidenceRecord.self, text)
                            if !record.deleted {
                                guard found == nil else { throw ContextError.invalid("Ambiguous citation prefix. Use its full evidence ID.") }
                                found = StoredEvidence(source: source, record: record)
                            }
                        }
                        code = sqlite3_step(statement)
                    }
                    guard code == SQLITE_DONE else { throw ContextError.database("Citation lookup failed; no partial result was accepted.") }
                }
                try execute("COMMIT"); return found
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    private static func isOlder(_ incoming: EvidenceRecord, than old: EvidenceRecord) -> Bool {
        guard let a = incoming.attributes["revisionTimestamp"].flatMap(EvidenceDates.parse),
              let b = old.attributes["revisionTimestamp"].flatMap(EvidenceDates.parse) else { return false }
        return a != b ? a < b : (incoming.attributes["revision"] ?? "") < (old.attributes["revision"] ?? "")
    }
    private func refreshRecords(_ sourceID: String, ids: Set<String>) throws {
        for id in ids {
            try Task.checkCancellation()
            let candidates = try rows("SELECT payload FROM owners WHERE source_id=? AND record_id=? ORDER BY snapshot DESC,file_id,document_id", [sourceID, id])
            guard let first = candidates.first else {
                try execute("DELETE FROM records WHERE source_id=? AND record_id=?", [sourceID, id]); continue
            }
            var winner = try decode(EvidenceRecord.self, first[0])
            for row in candidates.dropFirst() {
                let candidate = try decode(EvidenceRecord.self, row[0])
                if Self.isOlder(winner, than: candidate) { winner = candidate }
            }
            try execute("UPDATE records SET payload=? WHERE source_id=? AND record_id=?", [try encode(winner), sourceID, id])
        }
    }
    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try decoder.decode(type, from: Data(text.utf8)) }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        guard !values.contains(where: { $0.contains("\u{0}") }) else { throw ContextError.invalid("A source identifier contains a NUL character. No checkpoint was accepted; correct the export and retry.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ContextError.database("Could not read the context database schema. Existing data has been preserved.")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement); throw ContextError.database("Could not bind a context database value.")
            }
        }
        return statement
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw ContextError.database("Context database write failed (SQLite \(result)). Check free disk space or retry after other writers finish. No checkpoint was advanced.") }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var output: [[String]] = [], result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            output.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ContextError.database("Context database read failed (SQLite \(result)); no partial result was accepted.") }
        return output
    }
}
