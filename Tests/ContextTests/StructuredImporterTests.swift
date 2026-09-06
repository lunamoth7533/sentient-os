// End-to-end local imports from actual files through adapters and the durable store.
import XCTest
@testable import SentientContext

final class StructuredImporterTests: XCTestCase {
    func testSymlinkAncestorCannotBypassGeneratedRootExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-ancestor-\(UUID())")
        let generated = root.appendingPathComponent("Sentient OS - Knowledge Base/sub")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Derived content".utf8).write(to: generated.appendingPathComponent("note.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: generated)
        let source = ImportSource(kind: .markdown, path: root.appendingPathComponent("alias/note.md").path)
        XCTAssertThrowsError(try StructuredImporter.files(for: source))
    }
    func testMarkdownImportUpdateDeletionAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-import-\(UUID())")
        let input = root.appendingPathComponent("notes"), database = root.appendingPathComponent("db/evidence.sqlite")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = input.appendingPathComponent("Work.md")
        try "# Work\n\nKeep backups.\n".write(to: file, atomically: true, encoding: .utf8)
        let source = ImportSource(kind: .markdown, path: input.path, project: "/synthetic/work")
        let store = try EvidenceStore(url: database); try store.saveSource(source)
        let importer = StructuredImporter(store: store)
        XCTAssertEqual(try importer.run(source: source).state, "complete")
        XCTAssertEqual(try importer.run(source: source).records, 1)
        try "# Work\n\nCorrection: retain two backups.\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try importer.run(source: source)
        let reopened = try EvidenceStore(url: database)
        XCTAssertEqual(try reopened.evidence(audience: .local).count, 1)
        XCTAssertTrue(try reopened.evidence(audience: .local)[0].record.text.contains("two backups"))
        try FileManager.default.removeItem(at: file)
        _ = try importer.run(source: source)
        XCTAssertTrue(try reopened.evidence(audience: .local).isEmpty)
    }
    func testMalformedMiddleLineNeverSilentlySkipsLaterInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-jsonl-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("s.jsonl")
        try "{\"type\":\"one\"}\ninvalid\n{\"type\":\"three\"}\n".write(to: file, atomically: true, encoding: .utf8)
        let result = try StructuredInput.jsonLines(at: file)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.issues.first?.line, 2)
    }
    func testSentientOutputAndSymlinksCannotEnterNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-exclusion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("x.md"), link = root.appendingPathComponent("link.md")
        try "secret".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try StructuredInput.readData(at: link))
        XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "generated", text: "Derived", attributes: ["origin": "sentient"])))
        XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "secret", text: "api_key=sk-synthetic12345678901234567890")))
    }
}
