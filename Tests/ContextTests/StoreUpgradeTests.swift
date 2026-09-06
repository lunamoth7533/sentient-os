// Isolated v1 -> v2 rehearsal using the original schema; all content is artificial.
import XCTest
import SQLite3
@testable import SentientContext

final class StoreUpgradeTests: XCTestCase {
    func testNULIdentifiersCannotAliasOrAdvanceCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-nul-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        try store.saveSource(ImportSource(id: "s", kind: .codex, path: "/synthetic"))
        XCTAssertThrowsError(try store.commit(sourceID: "s", fileID: "f", fingerprint: "new", documents: [ImportDocument(id: "d", records: [EvidenceRecord(id: "same\u{0}one", text: "A"), EvidenceRecord(id: "same\u{0}two", text: "B")])]))
        XCTAssertEqual(try store.counts(sourceID: "s"), 0)
        XCTAssertFalse(try store.isCurrent(sourceID: "s", fileID: "f", fingerprint: "new"))
    }
    func testJSONLPhysicalLineLimitIncludesBlankLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-line-limit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.jsonl")
        try Data("{}\n\n{}\n".utf8).write(to: url)
        XCTAssertThrowsError(try StructuredInput.jsonLines(at: url, maximumLines: 2))
        XCTAssertEqual(try StructuredInput.jsonLines(at: url, maximumLines: 3).lines.map(\.number), [1, 3])
    }
    func testV1UpgradePreservesPayloadAndInvalidatesOnlyUnsafeCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("evidence.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        func sql(_ value: String) throws {
            guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw ContextError.database("Synthetic v1 setup failed") }
        }
        let source = ImportSource(id: "synthetic", kind: .lattice, path: "/synthetic/export.json")
        let record = EvidenceRecord(id: "zero", text: "Steps: 0; sleep: missing", role: .observation,
            project: "Synthetic wellness", timestamp: "2026-09-06T01:00:00-05:00", locator: "export.json:zero",
            attributes: ["unit":"count", "revision":"native-1"], sensitive: true)
        func literal<T: Encodable>(_ value: T) throws -> String {
            "'" + String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "'", with: "''") + "'"
        }
        try sql("CREATE TABLE sources(id TEXT PRIMARY KEY,payload TEXT NOT NULL,status TEXT)")
        try sql("CREATE TABLE records(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,record_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(source_id,record_id))")
        try sql("CREATE TABLE owners(source_id TEXT NOT NULL,file_id TEXT NOT NULL,document_id TEXT NOT NULL,record_id TEXT NOT NULL,PRIMARY KEY(source_id,file_id,document_id,record_id),FOREIGN KEY(source_id,record_id) REFERENCES records(source_id,record_id) ON DELETE CASCADE)")
        try sql("CREATE TABLE imports(source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,file_id TEXT NOT NULL,fingerprint TEXT NOT NULL,complete INTEGER NOT NULL,PRIMARY KEY(source_id,file_id))")
        try sql("INSERT INTO sources VALUES('synthetic',\(try literal(source)),NULL)")
        try sql("INSERT INTO records VALUES('synthetic','zero',\(try literal(record)))")
        try sql("INSERT INTO owners VALUES('synthetic','file','document','zero')")
        try sql("INSERT INTO imports VALUES('synthetic','file','durable',1)")
        try sql("PRAGMA user_version=1")
        sqlite3_close(db); db = nil
        for _ in 0..<2 {
            let upgraded = try EvidenceStore(url: url)
            XCTAssertEqual(try upgraded.sources(), [source])
            XCTAssertEqual(try upgraded.evidence(audience: .local).map(\.record), [record])
            XCTAssertTrue(try upgraded.evidence(audience: .shared).isEmpty)
            XCTAssertFalse(try upgraded.isCurrent(sourceID: source.id, fileID: "file", fingerprint: "durable"))
        }
    }
    func testFilteringIsAppliedBeforeTheMemoryLimitAndStaleConfigurationsCannotCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-limits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        var source = ImportSource(id: "s", kind: .codex, path: "/synthetic/sessions")
        try store.saveSource(source)
        let records = (0..<200).map { EvidenceRecord(id: "r\($0)", text: "Record \($0)", project: $0 == 0 ? "target" : "other") }
        try store.commit(sourceID: "s", fileID: "f", fingerprint: "one", documents: [ImportDocument(id: "d", records: records)])
        XCTAssertThrowsError(try store.evidence(audience: .local, limit: 10))
        XCTAssertEqual(try store.evidence(audience: .local, project: "target", limit: 10).count, 1)
        let previous = source; source.shareEnabled = true; try store.saveSource(source)
        XCTAssertThrowsError(try store.commit(sourceID: "s", fileID: "f", fingerprint: "bad", documents: [], expectedSource: previous))
        XCTAssertThrowsError(try store.reconcileFiles(sourceID: "s", retaining: [], expectedSource: previous))
        XCTAssertEqual(try store.counts(sourceID: "s"), 200)
    }
}
