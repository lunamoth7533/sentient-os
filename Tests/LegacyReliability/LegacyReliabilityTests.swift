// Durable behavioral regressions for retry checkpoints, atomic saves, imports, and SQLite snapshots.
import Foundation
import SwiftData
import SQLite3

nonisolated struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

struct FixtureConnector: Connector {
    enum Failure: Error { case extraction }
    let kind: SourceKind = .file
    let contents: [String: String]
    let failID: String?
    let fixtureBuckets: [Bucket]
    init(_ buckets: [(String, [Int])], failID: String? = nil, contents: [String: String] = [:]) {
        self.failID = failID
        self.contents = contents
        self.fixtureBuckets = buckets.map { bucket, numbers in
            Bucket(key: bucket, items: numbers.map { n in
                let id = "\(bucket)/\(n)"
                return (ItemKey(order: Double(n)), Candidate(id: id, kind: .file,
                    itemDate: Date(timeIntervalSince1970: Double(n))))
            })
        }
    }
    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] { fixtureBuckets }
    func load(_ item: Candidate) throws -> Artifact {
        if item.id == failID { throw Failure.extraction }
        return Artifact(candidate: item, text: contents[item.id] ?? "Synthetic fixture")
    }
}

@main struct LegacyReliabilityTests {
    @MainActor static func main() async {
        var failures = 0
        let selected = CommandLine.arguments.dropFirst().first
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("extraction_retry", extractionRetry),
            ("generation_retry", generationRetry),
            ("parse_retry", parseRetry),
            ("initial_resume", initialResume),
            ("cancel_does_not_commit", cancellation),
            ("junk_sensitive_zero_trace", junkAndSensitive),
            ("save_failure_stops_bucket", saveFailure),
            ("replace_failure_preserves_notes", replaceFailure),
            ("wipe_failure_preserves_notes", wipeFailure),
            ("wipe_only_consumed_snapshot", wipeConsumedSnapshot),
            ("import_idempotent", importIdempotent),
            ("chat_identity", chatIdentity),
            ("shared_open_preserves_store", sharedOpenPreserves),
            ("sqlite_step_error", sqliteStepError),
            ("sqlite_rejects_invalid_snapshot", sqliteInvalidSnapshot),
            ("sqlite_wal_snapshot", sqliteWALSnapshot),
            ("sqlite_concurrent_checkpoint", sqliteConcurrentCheckpoint)
        ]
        for (name, test) in cases where selected == nil || selected == name {
            do { try await test(); Swift.print("PASS \(name)") }
            catch { failures += 1; Swift.print("FAIL \(name): \(error)") }
        }
        Swift.print("Legacy reliability: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func store(at url: URL, readOnly: Bool = false) throws -> CycleStore {
        let schema = Schema([BucketPointer.self, CycleNote.self])
        let config = ModelConfiguration(schema: schema, url: url, allowsSave: !readOnly)
        return CycleStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }
    static func note(_ sourceID: String, bucket: String = "file:a", date: Double = 1,
                     text: String = "Synthetic note") -> CycleNoteItem {
        CycleNoteItem(id: sourceID, bucketKey: bucket, kind: .file, sourceID: sourceID, folder: "Fixture",
                      itemDate: Date(timeIntervalSince1970: date), text: text, title: nil,
                      reminderFlagged: false, createdAt: Date(timeIntervalSince1970: 100))
    }
    static func failureRetry(contents: [String: String], failID: String?, label: String) async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let first = try store(at: url)
        try await first.setPointer("file:a", ItemKey(order: 0))
        let connector = FixtureConnector([("file:a", [3, 2, 1]), ("file:b", [9])], failID: failID, contents: contents)
        let progress = await IterativeRun(modelPath: "fixture", store: first).run([connector], mode: .auto)
        let mark = await first.pointer("file:a")
        try check(mark?.order == 1, "\(label) advanced beyond failed item: \(String(describing: mark))")
        try check(progress.failed == 1, "\(label) was not surfaced as a failure")
        try check(progress.errorMessage != nil && progress.done == 2 && progress.survivors == 2,
                  "Deferred failure was hidden or counted as committed progress")
        try check(await first.pointer("file:b")?.order == 9, "Independent bucket did not progress")
        let reopened = try store(at: url)
        let repaired = FixtureConnector([("file:a", [3, 2, 1])])
        _ = await IterativeRun(modelPath: "fixture", store: reopened).run([repaired], mode: .auto)
        let notes = await reopened.notes()
        try check(Set(notes.map(\.sourceID)) == ["file:a/1", "file:a/2", "file:a/3", "file:b/9"], "Restart lost failed work")
        try check(notes.count == 4, "Retry duplicated earlier survivors")
    }
    static func extractionRetry() async throws {
        try await failureRetry(contents: [:], failID: "file:a/2", label: "Extraction failure")
    }
    static func generationRetry() async throws {
        try await failureRetry(contents: ["file:a/2": "FIXTURE_GENERATION_FAILURE"], failID: nil, label: "Generation failure")
    }
    static func parseRetry() async throws {
        try await failureRetry(contents: ["file:a/2": "FIXTURE_PARSE_FAILURE"], failID: nil, label: "Malformed model output")
        try await failureRetry(contents: ["file:a/2": "FIXTURE_EMPTY_SUMMARY"], failID: nil, label: "Incomplete survivor output")
    }
    static func initialResume() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let first = try store(at: url)
        _ = await IterativeRun(modelPath: "fixture", store: first).run(
            [FixtureConnector([("file:a", [3, 2, 1])], failID: "file:a/2")], mode: .auto)
        let state = try await first.pointerState("file:a")
        try check(state?.mark.order == 3 && state?.floor?.order == 3, "Failed initial item collapsed or sank the floor")
        let reopened = try store(at: url)
        _ = await IterativeRun(modelPath: "fixture", store: reopened).run([FixtureConnector([("file:a", [3, 2, 1])])], mode: .auto)
        let final = try await reopened.pointerState("file:a")
        try check(final?.mark.order == 3 && final?.floor == nil, "Successful resume did not finish descent")
        try check(await reopened.notes().count == 3, "Resume lost or duplicated notes")
    }
    static func cancellation() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(at: dir.appendingPathComponent("cycle.store"))
        let task = Task { await IterativeRun(modelPath: "cancel", store: store).run([FixtureConnector([("file:a", [1])])], mode: .auto) }
        let progress = await task.value
        try check(progress.cancelled && progress.done == 0 && progress.survivors == 0, "Cancellation reported successful work")
        try check(await store.pointer("file:a") == nil, "Cancelled generation committed a pointer")
        try check(await store.notes().isEmpty, "Cancelled generation committed a note")
    }
    static func junkAndSensitive() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(at: dir.appendingPathComponent("cycle.store"))
        let connector = FixtureConnector([("file:a", [2, 1])], contents: ["file:a/1": "FIXTURE_JUNK", "file:a/2": "FIXTURE_SENSITIVE"])
        let progress = await IterativeRun(modelPath: "fixture", store: store).run([connector], mode: .auto)
        try check(progress.junk == 1 && progress.sensitive == 1 && progress.done == 2, "Valid drops were not consumed")
        try check(await store.notes().isEmpty, "Junk or sensitive content persisted")
        try check(try await store.pointerState("file:a")?.floor == nil, "Successful zero-trace descent did not finish")
    }
    static func saveFailure() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let writable = try store(at: url)
        try await writable.setPointer("file:a", ItemKey(order: 0))
        let readOnly = try store(at: url, readOnly: true)
        let progress = await IterativeRun(modelPath: "fixture", store: readOnly).run([FixtureConnector([("file:a", [2, 1])])], mode: .auto)
        try check(progress.failed == 1 && progress.done == 0, "Terminal save failure was reported as successful progress")
        try check(await readOnly.pointer("file:a")?.order == 0, "Save failure left an advanced in-memory mark")
        let reopened = try store(at: url)
        try check(await reopened.notes().isEmpty, "Save failure partially persisted note")
        _ = await IterativeRun(modelPath: "fixture", store: reopened).run([FixtureConnector([("file:a", [2, 1])])], mode: .auto)
        try check(await reopened.notes().count == 2, "Writable restart did not recover failed survivors")
    }
    static func replaceFailure() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let writable = try store(at: url)
        try await writable.importNotes([note("original")], replace: false)
        let readOnly = try store(at: url, readOnly: true)
        var rejected = false
        do { try await readOnly.importNotes([note("replacement")], replace: true) }
        catch { rejected = true }
        try check(rejected, "Read-only replacement reported success")
        let reopened = try store(at: url)
        try check(await reopened.notes().map(\.sourceID) == ["original"], "Failed replacement lost original notes")
    }
    static func importIdempotent() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let store = try store(at: url)
        try await store.setPointer("file:a", ItemKey(order: 7))
        try await store.importNotes([note("one")], replace: false)
        try await store.importNotes([note("one"), note("one")], replace: false)
        let reopened = try self.store(at: url)
        try check(await reopened.notes().count == 1, "Repeated import duplicated a note")
        try check(await reopened.pointer("file:a")?.order == 7, "Import changed processing pointer")
        try await reopened.importNotes([note("one", text: "Updated synthetic note")], replace: false)
        let updated = try await reopened.readNotes()
        try check(updated.count == 1 && updated.first?.text == "Updated synthetic note", "Merge did not update existing identity")
        try check(updated.first?.createdAt == Date(timeIntervalSince1970: 100), "Import changed source creation date")
    }
    static func wipeFailure() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let writable = try store(at: url)
        try await writable.importNotes([note("original")], replace: false)
        try await writable.setPointer("file:a", ItemKey(order: 7))
        let readOnly = try store(at: url, readOnly: true)
        var rejected = false
        do { try await readOnly.wipeAllNotesDurably() }
        catch { rejected = true }
        try check(rejected, "Failed cycle-end wipe reported success")
        let reopened = try store(at: url)
        try check(try await reopened.readNotes().count == 1, "Failed wipe lost durable notes")
        try await reopened.wipeAllNotesDurably()
        try check(try await reopened.readNotes().isEmpty, "Successful wipe retained notes")
        try check(await reopened.pointer("file:a")?.order == 7, "Cycle-end wipe changed durable pointer")
    }
    static func chatIdentity() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(at: dir.appendingPathComponent("cycle.store"))
        try await store.importNotes([note("chat", bucket: "whatsapp:fixture", date: 1), note("chat", bucket: "whatsapp:fixture", date: 2)], replace: false)
        let notes = await store.notes()
        try check(notes.count == 2 && Set(notes.map(\.id)).count == 2, "Distinct chat windows collide in Identifiable IDs")
    }
    static func wipeConsumedSnapshot() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cycle.store")
        let store = try store(at: url)
        try await store.importNotes([note("consumed"), note("revised"), note("recreated")], replace: false)
        let snapshot = try await store.readNotes()
        let original = snapshot.first { $0.sourceID == "recreated" }!
        let recreated = CycleNoteItem(id: original.id, bucketKey: original.bucketKey, kind: original.kind,
            sourceID: original.sourceID, folder: original.folder, itemDate: original.itemDate,
            text: original.text, title: original.title, reminderFlagged: original.reminderFlagged,
            createdAt: original.createdAt.addingTimeInterval(1))
        try await store.importNotes([note("new"), note("revised", text: "New revision not consumed by cloud"), recreated], replace: false)
        try await store.wipeNotesDurably(matching: snapshot)
        let reopened = try self.store(at: url)
        let surviving = try await reopened.readNotes()
        try check(Set(surviving.map(\.sourceID)) == ["new", "revised", "recreated"], "Cycle cleanup deleted new or revised notes that were never consumed")
        try check(surviving.first { $0.sourceID == "revised" }?.text == "New revision not consumed by cloud", "Revised note content was not retained")
    }
    static func sharedOpenPreserves() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        setenv("SENTIENT_RELIABILITY_SUPPORT", dir.path, 1)
        let url = dir.appendingPathComponent("IterativeCycle.store")
        let original = Data("Synthetic unreadable store. Preserve for recovery.".utf8)
        try original.write(to: url)
        let wal = URL(fileURLWithPath: url.path + "-wal"), shm = URL(fileURLWithPath: url.path + "-shm")
        let sidecar = Data("Synthetic recovery sidecar".utf8)
        try sidecar.write(to: wal); try sidecar.write(to: shm)
        _ = await CycleStore.shared.notes()
        try check(try Data(contentsOf: url) == original, "Shared-open recovery deleted the existing store")
        try check(try Data(contentsOf: wal) == sidecar && Data(contentsOf: shm) == sidecar, "Shared-open recovery deleted sidecars")
        var rejected = false
        do { try await CycleStore.shared.importNotes([note("unexpected")], replace: false) }
        catch { rejected = true }
        try check(rejected, "Unavailable store accepted a write into replacement memory")
        let progress = await IterativeRun(modelPath: "fixture", store: .shared).run([FixtureConnector([("file:a", [1])])], mode: .auto)
        try check(progress.errorMessage != nil && progress.failed == 1 && progress.done == 0, "Unavailable storage was presented as successful analysis")
    }

    nonisolated static func openSQLite(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CheckFailure("SQLite fixture open") }
        return db
    }
    nonisolated static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CheckFailure(String(cString: sqlite3_errmsg(db))) }
    }
    static func sqliteStepError() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.sqlite")
        let db = try openSQLite(url); sqlite3_close(db)
        let reader = try SQLiteReader(path: url.path)
        var rows = 0, threw = false
        do { try reader.forEachRow("SELECT 1 UNION ALL SELECT abs(-9223372036854775808)") { _ in rows += 1 } }
        catch { threw = true }
        try check(rows == 1 && threw, "Query returned partial rows as success after sqlite3_step failed")
    }
    static func sqliteInvalidSnapshot() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.sqlite")
        try Data("Not a SQLite database".utf8).write(to: url)
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("sentientos-db-") })
        var rejected = false
        do {
            let copy = try SQLiteDB.walSafeCopy(of: url.path)
            try? FileManager.default.removeItem(at: copy.dir)
        } catch { rejected = true }
        try check(rejected, "Invalid source returned a supposedly usable snapshot")
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("sentientos-db-") })
        try check(after == before, "Failed snapshot leaked a temporary plaintext directory")
    }
    static func sqliteWALSnapshot() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.sqlite")
        let db = try openSQLite(url); defer { sqlite3_close(db) }
        try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture(n INTEGER); INSERT INTO fixture VALUES(1); PRAGMA wal_checkpoint(TRUNCATE); INSERT INTO fixture VALUES(2);")
        let copy = try SQLiteDB.walSafeCopy(of: url.path)
        defer { try? FileManager.default.removeItem(at: copy.dir) }
        try execute(db, "INSERT INTO fixture VALUES(3); PRAGMA wal_checkpoint(TRUNCATE);")
        let reader = try SQLiteReader(path: copy.db.path)
        var numbers: [Int64] = []
        try reader.forEachRow("SELECT n FROM fixture ORDER BY n") { numbers.append($0.int(0)) }
        try check(numbers == [1, 2], "Snapshot lost committed WAL rows or changed with the source")
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.dir.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Snapshot directory is not private")
    }

    static func sqliteConcurrentCheckpoint() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("concurrent.sqlite")
        let db = try openSQLite(url)
        try execute(db, "PRAGMA journal_mode=WAL; CREATE TABLE fixture(n INTEGER PRIMARY KEY, generation INTEGER, padding BLOB); WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 128) INSERT INTO fixture SELECT n, 0, zeroblob(4096) FROM numbers;")
        sqlite3_close(db)
        let writer = Task.detached {
            let connection = try openSQLite(url)
            defer { sqlite3_close(connection) }
            sqlite3_busy_timeout(connection, 1000)
            for generation in 1...250 {
                try execute(connection, "BEGIN IMMEDIATE; UPDATE fixture SET generation=\(generation); COMMIT; PRAGMA wal_checkpoint(TRUNCATE);")
            }
        }
        // Every source transaction changes all 128 rows together. A snapshot may observe any
        // generation, but mixed generations or missing rows reveal a torn DB/WAL checkpoint copy.
        var snapshotFailure: Error?
        do {
            for _ in 0..<60 {
                let copy = try SQLiteDB.walSafeCopy(of: url.path)
                defer { try? FileManager.default.removeItem(at: copy.dir) }
                let reader = try SQLiteReader(path: copy.db.path)
                var valid = false
                try reader.forEachRow("SELECT COUNT(*), MIN(generation), MAX(generation) FROM fixture") {
                    valid = $0.int(0) == 128 && $0.int(1) == $0.int(2)
                }
                try check(valid, "Snapshot mixed rows across an atomic update/checkpoint")
            }
        } catch { snapshotFailure = error }
        // Always join the writer before deleting its temporary store, including assertion failure.
        try await writer.value
        if let snapshotFailure { throw snapshotFailure }
    }
}
