// The graph and mirror projections must follow the same current evidence and permissions as retrieval.
import XCTest
@testable import SentientContext

final class ProjectionTests: XCTestCase {
    func testProjectOverviewIncludesCrossSessionDecisionsAndOpenWorkWithoutMergingSources() throws {
        let source = ImportSource(id: "one", kind: .codex, path: "/synthetic/one")
        let other = ImportSource(id: "two", kind: .codex, path: "/synthetic/two")
        let records = [
            EvidenceRecord(id: "decision", text: "Decision: preserve the existing store.", role: .user, sessionID: "first", project: "Atlas", locator: "fixture:decision"),
            EvidenceRecord(id: "next", text: "Next action: verify restart recovery.", role: .user, sessionID: "second", project: "Atlas", locator: "fixture:next")
        ]
        let evidence = records.map { StoredEvidence(source: source, record: $0) } + [StoredEvidence(source: other, record: EvidenceRecord(id: "unrelated", text: "Different source with the same project name.", project: "Atlas"))]
        let notes = try ContextProjection.notes(evidence: evidence, audience: .local)
        let overview = try XCTUnwrap(notes["\(EvidenceIdentity.digest(source.id + "\u{0}Atlas").prefix(12))/Project.md"])
        XCTAssertTrue(overview.contains("preserve the existing store"))
        XCTAssertTrue(overview.contains("verify restart recovery"))
        XCTAssertTrue(overview.contains("fixture:decision"))
        XCTAssertTrue(overview.contains("fixture:next"))
        XCTAssertTrue(overview.contains("Assistant proposals and reports are unverified"))
        XCTAssertFalse(overview.contains("Different source"))
    }
    func testSummaryOrderingUsesActualInstantsAcrossOffsets() throws {
        let source = ImportSource(id: "one", kind: .codex, path: "/synthetic")
        let records = [
            EvidenceRecord(id: "older", text: "Older constraint", role: .user, sessionID: "s", timestamp: "2026-09-06T09:00:00+09:00"),
            EvidenceRecord(id: "newer", text: "Newer constraint", role: .user, sessionID: "s", timestamp: "2026-09-06T01:00:00Z")
        ]
        let notes = try ContextProjection.notes(evidence: records.map { StoredEvidence(source: source, record: $0) }, audience: .local)
        let session = try XCTUnwrap(notes.first { $0.key.contains("Session-") }?.value)
        XCTAssertLessThan(try XCTUnwrap(session.range(of: "Newer constraint")?.lowerBound), try XCTUnwrap(session.range(of: "Older constraint")?.lowerBound))
    }
    func testImportedTextCannotCreateGraphEdgesOrOverrideAttribution() throws {
        let source = ImportSource(id: "test", kind: .markdown, path: "/synthetic")
        let r = EvidenceRecord(id: "r", text: "Literal [[Imported/other/Session-invented]]\n# Confirmed success", role: .assistant, sessionID: "Quoted [[fake]]")
        let notes = try ContextProjection.notes(evidence: [StoredEvidence(source: source, record: r)], audience: .local)
        let session = try XCTUnwrap(notes.first { $0.key.contains("Session-") }?.value)
        XCTAssertFalse(session.contains("[[Imported/other/Session-invented]]"))
        XCTAssertFalse(session.contains("# Confirmed success"))
        XCTAssertTrue(session.contains("Assistant proposals and reports are unverified"))
    }
    func testCorrectionsDeletionAndSharingRebuildTheProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-projection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("db/evidence.sqlite"))
        var source = ImportSource(id: "test", kind: .metricsCSV, path: "/synthetic/metrics.csv")
        try store.saveSource(source)
        let r = EvidenceRecord(id: "steps", text: "0 steps on 2026-09-06", role: .observation, project: "demo", sensitive: true)
        try store.commit(sourceID: source.id, fileID: "f", fingerprint: "1", documents: [ImportDocument(id: "d", records: [r])])
        XCTAssertTrue(try ContextProjection.notes(store: store, audience: .shared).isEmpty)
        var notes = try ContextProjection.notes(store: store, audience: .local)
        XCTAssertTrue(notes.values.joined().contains("0 steps"))
        XCTAssertTrue(notes.values.joined().contains("observation"))
        source.shareEnabled = true; try store.saveSource(source)
        XCTAssertTrue(try ContextProjection.notes(store: store, audience: .shared).values.joined().contains("2026-09-06"))
        try store.commit(sourceID: source.id, fileID: "f", fingerprint: "2", documents: [ImportDocument(id: "d", records: [EvidenceRecord(id: "steps", text: "100 steps", role: .observation, project: "demo", sensitive: true)])])
        notes = try ContextProjection.notes(store: store, audience: .local)
        XCTAssertFalse(notes.values.joined().contains("0 steps on"))
        try ContextProjection.refresh(store: store, root: root.appendingPathComponent("Imported"))
        try store.removeSource(source.id)
        try ContextProjection.refresh(store: store, root: root.appendingPathComponent("Imported"))
        XCTAssertFalse(try ContextProjection.notes(store: store, audience: .local).values.joined().contains("100 steps"))
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Imported"), includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
        XCTAssertTrue(files.isEmpty)
    }
    func testPrivacyFilteringRetainsDatesButRejectsSecretMetadata() {
        XCTAssertEqual(EvidencePrivacy.sharingText("2026-09-06 0 steps"), "2026-09-06 0 steps")
        XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "x", text: "ordinary", attributes: ["password": "synthetic-password-123"])))
    }
}
