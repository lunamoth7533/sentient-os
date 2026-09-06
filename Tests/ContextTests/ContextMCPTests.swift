// MCP callers cannot widen the fixed server audience or bypass source permissions by guessing IDs.
import XCTest
@testable import SentientContext

final class ContextMCPTests: XCTestCase {
    func testMetadataCatalogPagesAndPointCitationsRecheckPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        var source = ImportSource(id: "s", kind: .codex, path: "/synthetic", shareEnabled: true)
        try store.saveSource(source)
        let records = (0..<12).map { EvidenceRecord(id: "r\($0)", text: "Synthetic body", project: "project-\($0)") }
        try store.commit(sourceID: "s", fileID: "f", fingerprint: "one", documents: [ImportDocument(id: "d", records: records)])
        XCTAssertThrowsError(try store.evidence(audience: .shared, limit: 1))
        XCTAssertEqual(try store.projects(sourceID: "s", audience: .shared).count, 9)
        XCTAssertEqual(try store.projects(sourceID: "s", audience: .shared, offset: 8).count, 4)
        let stored = StoredEvidence(source: source, record: records[0])
        XCTAssertEqual(try store.evidence(idPrefix: stored.id, audience: .shared)?.record, records[0])
        let citation = ContextCitation(id: stored.id, sourceID: "s", recordID: records[0].id, locator: "", timestamp: nil)
        XCTAssertEqual(try store.evidence(citation: citation, audience: .shared)?.record, records[0])
        source.shareEnabled = false; try store.saveSource(source)
        XCTAssertTrue(try store.projects(sourceID: "s", audience: .shared).isEmpty)
        XCTAssertNil(try store.evidence(idPrefix: stored.id, audience: .shared))
        XCTAssertNil(try store.evidence(citation: citation, audience: .shared))
    }
    func testInvalidFilterTypesCannotSilentlyWidenTheQuery() {
        for argument: [String: Any] in [["project":3], ["source":false], ["budget":"1024"], ["budget":true], ["include_graph":"yes"]] {
            var query: [String: Any] = ["query":"project decision"]
            query.merge(argument) { _, new in new }
            XCTAssertThrowsError(try ContextMCP.query(query))
        }
    }
    func testSharedProjectIDsWorkWithoutExposingPrivatePathOrWarningLabel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-mcp-project-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        let source = ImportSource(id: "s", kind: .codex, path: "/synthetic", label: "synthetic@example.invalid", shareEnabled: true)
        try store.saveSource(source)
        let project = "/Volumes/Synthetic Disk/Private/Project"
        try store.commit(sourceID: "s", fileID: "f", fingerprint: "one", documents: [ImportDocument(id: "d", records: [EvidenceRecord(id: "r", text: "Use SQLite", project: project)])])
        try store.setStatus(ImportStatus(state: "partial"), sourceID: "s")
        let server = ContextMCP(store: store)
        _ = server.handle(["jsonrpc":"2.0", "id":1, "method":"initialize"])
        _ = server.handle(["jsonrpc":"2.0", "method":"notifications/initialized"])
        let response = server.handle(["jsonrpc":"2.0", "id":2, "method":"tools/call", "params":["name":"list_context_sources"]])!
        let listed = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        XCTAssertFalse(listed.contains("Private")); XCTAssertFalse(listed.contains("example.invalid"))
        let key = EvidenceIdentity.projectKey(sourceID: "s", project: project)
        XCTAssertTrue(listed.contains(key))
        let result = try ContextRetriever.retrieve(store: store, query: ContextQuery(text: "SQLite", project: key), audience: .shared)
        XCTAssertEqual(result.citations.count, 1)
        XCTAssertFalse(result.text.contains("Private")); XCTAssertFalse(result.text.contains("example.invalid"))
    }
    func testHandshakeSearchAndPermissionRevocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-mcp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        var source = ImportSource(id: "health", kind: .metricsCSV, path: "/synthetic/metrics.csv")
        try store.saveSource(source)
        try store.commit(sourceID: source.id, fileID: "f", fingerprint: "1", documents: [ImportDocument(id: "d", records: [EvidenceRecord(id: "r", text: "Daily steps: 0", sensitive: true)])])
        let server = ContextMCP(store: store)
        let initialized = server.handle(["jsonrpc":"2.0", "id":1, "method":"initialize", "params":["protocolVersion":"2025-11-25"]])
        XCTAssertNotNil(initialized?["result"])
        _ = server.handle(["jsonrpc":"2.0", "method":"notifications/initialized"])
        func search(_ extra: [String: Any] = [:]) -> String {
            var args: [String: Any] = ["query":"daily steps"]
            args.merge(extra) { _, new in new }
            let reply = server.handle(["jsonrpc":"2.0", "id":2, "method":"tools/call", "params":["name":"search_context", "arguments":args]])!
            return String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        }
        XCTAssertFalse(search().contains("Daily steps: 0"))
        XCTAssertFalse(search(["audience":"local"]).contains("Daily steps: 0"))
        source.shareEnabled = true; try store.saveSource(source)
        XCTAssertTrue(search().contains("Daily steps: 0"))
        source.contextEnabled = false; try store.saveSource(source)
        XCTAssertFalse(search().contains("Daily steps: 0"))
    }
    func testMCPHasNoMutationToolsAndNoPrivateSourceListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-mcp-list-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        try store.saveSource(ImportSource(id: "private-label", kind: .lattice, path: "/synthetic/lattice"))
        let server = ContextMCP(store: store)
        _ = server.handle(["jsonrpc":"2.0", "id":1, "method":"initialize", "params":["protocolVersion":"2025-11-25"]])
        _ = server.handle(["jsonrpc":"2.0", "method":"notifications/initialized"])
        let response = server.handle(["jsonrpc":"2.0", "id":2, "method":"tools/call", "params":["name":"list_context_sources", "arguments":[:]]])!
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self).contains("private-label"))
        XCTAssertNil(server.handle(["jsonrpc":"2.0", "method":"notifications/cancelled", "params":["requestId":3]]))
    }
}
