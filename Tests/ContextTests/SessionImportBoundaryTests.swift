// Large and interrupted imports use artificial native sessions and isolated stores.
import XCTest
import Foundation
@testable import SentientContext

final class SessionImportBoundaryTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-session-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testLongNativeSessionRetainsStableIDsAndLatestSameIDCorrection() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.jsonl")
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"long-session\",\"cwd\":\"/synthetic/long\"}}\n".utf8)
        for index in 0..<8_000 {
            data.append(Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"id\":\"message-\(index)\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Artificial record \(index)\"}]}}\n".utf8))
        }
        data.append(Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"id\":\"message-0\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Correction: artificial replacement\"}]}}\n".utf8))
        try data.write(to: file)
        let source = ImportSource(kind: .codex, path: file.path)
        let doc = try XCTUnwrap(SessionAdapters.parse(url: file, source: source).first)
        XCTAssertTrue(doc.complete)
        XCTAssertEqual(doc.records.count, 8_000)
        XCTAssertEqual(doc.records.first { $0.id == "long-session:message-0" }?.text, "Correction: artificial replacement")
        data.append(Data("{\"type\":".utf8)); try data.write(to: file)
        let interrupted = try XCTUnwrap(SessionAdapters.parse(url: file, source: source).first)
        XCTAssertFalse(interrupted.complete)
        XCTAssertEqual(interrupted.records.count, 8_000)
        XCTAssertFalse(interrupted.issues.isEmpty)
    }

    func testOversizedNativeSessionIsRejectedBeforeDecoding() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(StructuredInput.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try SessionAdapters.parse(url: file, source: ImportSource(kind: .codex, path: file.path))) { error in
            guard case ContextError.limit = error else { return XCTFail("Expected a bounded-input error before JSON decoding.") }
        }
    }

    @MainActor func testCancelledImportKeepsPriorEvidenceAndCheckpoint() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cancel.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"cancel-session\"}}\n".write(to: file, atomically: true, encoding: .utf8)
        let source = ImportSource(kind: .codex, path: file.path)
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        try store.saveSource(source)
        try store.commit(sourceID: source.id, fileID: file.path, fingerprint: "previous", documents: [ImportDocument(id: "previous-session", records: [EvidenceRecord(id: "previous", text: "Retained artificial evidence")])])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try StructuredImporter(store: store).run(source: source, progress: { status in
                if status.state == "running", status.files == 0 {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
            })
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        worker.cancel(); release.signal()
        let status = try await worker.value
        XCTAssertTrue(started)
        XCTAssertEqual(status.state, "cancelled")
        XCTAssertEqual(try store.evidence(audience: .local).map(\.record.text), ["Retained artificial evidence"])
        XCTAssertTrue(try store.isCurrent(sourceID: source.id, fileID: file.path, fingerprint: "previous"))
    }
}
