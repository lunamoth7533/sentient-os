// Durable import regressions: use real SQLite on temporary synthetic stores.
import XCTest
@testable import SentientContext

final class EvidenceStoreTests: XCTestCase {
    func testProjectConfigurationChangeInvalidatesTheCheckpoint() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "same", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "Work")])])
        var changed = source; changed.project = "New default project"; try store.saveSource(changed)
        XCTAssertFalse(try store.isCurrent(sourceID: source.id, fileID: "a", fingerprint: "same"))
    }
    func testFailedCommitRollsBackEarlierDocumentsAndCheckpoint() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "old", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "old", text: "Keep")])])
        XCTAssertThrowsError(try store.commit(sourceID: source.id, fileID: "a", fingerprint: "new", documents: [
            ImportDocument(id: "s", records: [EvidenceRecord(id: "new", text: "Tentative")]),
            ImportDocument(id: "broken", records: [EvidenceRecord(id: "duplicate", text: "1"), EvidenceRecord(id: "duplicate", text: "2")])]))
        let reopened = try EvidenceStore(url: store.url)
        XCTAssertEqual(try reopened.evidence(audience: .local).map(\.record.text), ["Keep"])
        XCTAssertTrue(try reopened.isCurrent(sourceID: source.id, fileID: "a", fingerprint: "old"))
    }
    func workspace() throws -> (URL, EvidenceStore, ImportSource) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-evidence-test-\(UUID())")
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        let source = ImportSource(id: "test", kind: .codex, path: root.appendingPathComponent("source").path)
        try store.saveSource(source)
        return (root, store, source)
    }
    func testRepeatImportAndRestartHaveOneCurrentRecord() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = ImportDocument(id: "s1", records: [EvidenceRecord(id: "r1", text: "Keep checkpoints durable.", role: .user)])
        try store.commit(sourceID: source.id, fileID: "a.jsonl", fingerprint: "one", documents: [doc])
        try store.commit(sourceID: source.id, fileID: "a.jsonl", fingerprint: "one", documents: [doc])
        let reopened = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        XCTAssertEqual(try reopened.evidence(audience: .local).count, 1)
        XCTAssertTrue(try reopened.isCurrent(sourceID: source.id, fileID: "a.jsonl", fingerprint: "one"))
    }
    func testCorrectionAndDeletionReconcileRecords() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "Friday"), EvidenceRecord(id: "obsolete", text: "Old")])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "1", documents: [first])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "2", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "Monday")])])
        XCTAssertEqual(try store.evidence(audience: .local).map(\.record.text), ["Monday"])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "3", documents: [ImportDocument(id: "s", records: [])])
        XCTAssertTrue(try store.evidence(audience: .local).isEmpty)
    }
    func testPartialInputKeepsUnseenRecordsAndDoesNotAcceptCheckpoint() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "1", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "a", text: "A"), EvidenceRecord(id: "b", text: "B")])])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "partial", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "a", text: "corrected")], complete: false)])
        XCTAssertEqual(try store.evidence(audience: .local).count, 2)
        XCTAssertFalse(try store.isCurrent(sourceID: source.id, fileID: "a", fingerprint: "partial"))
    }
    func testRotationKeepsAnotherDocumentsOwnership() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "R")])
        try store.commit(sourceID: source.id, fileID: "old", fingerprint: "1", documents: [doc])
        try store.commit(sourceID: source.id, fileID: "rotated", fingerprint: "1", documents: [doc])
        try store.reconcileFiles(sourceID: source.id, retaining: ["rotated"])
        XCTAssertEqual(try store.evidence(audience: .local).count, 1)
    }
    func testRemovingNewestCopyRestoresRemainingOwnersEvidenceAndLocator() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "old", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "Old remaining copy", locator: "a:1")])])
        try store.commit(sourceID: source.id, fileID: "b", fingerprint: "new", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "New removed copy", locator: "b:1")])])
        try store.reconcileFiles(sourceID: source.id, retaining: ["a"])
        let remaining = try store.evidence(audience: .local).first?.record
        XCTAssertEqual(remaining?.text, "Old remaining copy")
        XCTAssertEqual(remaining?.locator, "a:1")
    }
    func testDisableExcludeShareAndRemoveHaveDifferentEffects() throws {
        let (root, store, initial) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        var source = initial
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "1", documents: [ImportDocument(id: "s", records: [EvidenceRecord(id: "r", text: "R")])])
        XCTAssertTrue(try store.evidence(audience: .shared).isEmpty)
        source.enabled = false; try store.saveSource(source)
        XCTAssertEqual(try store.evidence(audience: .local).count, 1)
        XCTAssertThrowsError(try store.commit(sourceID: source.id, fileID: "a", fingerprint: "2", documents: []))
        source.shareEnabled = true; try store.saveSource(source)
        XCTAssertEqual(try store.evidence(audience: .shared).count, 1)
        source.contextEnabled = false; try store.saveSource(source)
        XCTAssertTrue(try store.evidence(audience: .shared).isEmpty)
        XCTAssertTrue(try store.evidence(audience: .local).isEmpty)
        try store.removeSource(source.id)
        XCTAssertTrue(try store.sources().isEmpty)
    }
    func testOldCorrectionsAndCapsuleOmissionsCannotEraseNewerEvidence() throws {
        let (root, store, source) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let newer = EvidenceRecord(id: "r", text: "Monday", attributes: ["revisionTimestamp": "2026-09-06T12:00:00Z", "revision": "b"])
        let older = EvidenceRecord(id: "r", text: "Friday", attributes: ["revisionTimestamp": "2026-09-05T12:00:00Z", "revision": "a"])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "1", documents: [ImportDocument(id: "s", records: [newer], replaceExisting: false)])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "2", documents: [ImportDocument(id: "s", records: [older], replaceExisting: false)])
        try store.commit(sourceID: source.id, fileID: "a", fingerprint: "3", documents: [ImportDocument(id: "s", records: [], replaceExisting: false)])
        XCTAssertEqual(try store.evidence(audience: .local).first?.record.text, "Monday")
    }
    func testUnrecognizedStoreNeverGetsDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("evidence.sqlite"), data = Data("preserve-this".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try EvidenceStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
