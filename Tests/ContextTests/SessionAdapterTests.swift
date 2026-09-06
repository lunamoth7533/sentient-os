import XCTest
import Foundation
import SQLite3
@testable import SentientContext

final class SessionAdapterTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Sessions/\(name)")
    }
    private func parse(_ name: String, _ kind: ImportSourceKind) throws -> [ImportDocument] {
        let url = fixture(name)
        return try SessionAdapters.parse(url: url, source: ImportSource(kind: kind, path: url.path))
    }
    private func temporary(_ suffix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(suffix)
    }
    private func write(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func sql(_ db: OpaquePointer?, _ query: String) throws {
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw ContextError.database("Synthetic fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))") }
    }
    private func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    func testCodexMirroredItemsAppearOnceWithRolesAndTurnModel() throws {
        let doc = try XCTUnwrap(parse("codex.jsonl", .codex).first)
        XCTAssertEqual(doc.id, "codex-one")
        XCTAssertTrue(doc.complete)
        XCTAssertEqual(doc.records.filter { $0.text == "Inspect the artificial build." }.count, 1)
        let assistant = try XCTUnwrap(doc.records.first { $0.text == "I propose checking the build." })
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.model, "synthetic-model")
        XCTAssertEqual(assistant.provider, "openai")
        XCTAssertEqual(assistant.application, "Codex Desktop")
        XCTAssertEqual(assistant.project, "/synthetic/alpha")
        XCTAssertTrue(assistant.links.contains { $0.relation == "parent_session" && $0.target == "parent-one" })
        XCTAssertEqual(doc.records.filter { $0.role == .tool && $0.text.contains("Artificial process") }.count, 1)
        XCTAssertTrue(doc.records.contains { $0.role == .summary && $0.text.contains("summarized") })
    }

    func testClaudeKeepsSplitBlocksAndClassifiesUserEnvelopeToolResults() throws {
        let doc = try XCTUnwrap(parse("claude.jsonl", .claudeCode).first)
        XCTAssertEqual(doc.id, "claude-one")
        XCTAssertTrue(doc.records.contains { $0.text == "I will inspect it." && $0.role == .assistant })
        XCTAssertTrue(doc.records.contains { $0.kind == "tool_call" && $0.text.contains("Read") })
        let result = try XCTUnwrap(doc.records.first { $0.text == "Artificial file contents." })
        XCTAssertEqual(result.role, .tool)
        XCTAssertTrue(result.links.contains { $0.relation == "tool_call" && $0.target == "claude-one:ca-tool" })
        XCTAssertEqual(doc.records.filter { $0.text == "Artificial file contents." }.count, 1)
        XCTAssertTrue(doc.records.contains { $0.role == .boundary })
        XCTAssertEqual(Set(doc.records.map(\.id)).count, doc.records.count)
    }

    func testOpenClawJSONLLinksToolsWithoutDuplicatingAliasedPayloads() throws {
        let doc = try XCTUnwrap(parse("openclaw.jsonl", .openClaw).first)
        XCTAssertEqual(doc.id, "claw-one")
        let result = try XCTUnwrap(doc.records.first { $0.text == "Artificial result." })
        XCTAssertEqual(result.role, .tool)
        XCTAssertTrue(result.links.contains { $0.relation == "tool_call" && $0.target == "claw-one:claw-call" })
        XCTAssertEqual(result.provider, "synthetic-provider")
        XCTAssertTrue(doc.records.contains { $0.role == .summary && $0.text == "Artificial earlier context." })
    }

    func testOpenClawToolEnvelopePreservesFailureAndDoesNotInventSuccess() throws {
        let url = try temporary("tool-envelope.jsonl")
        try write([
            ["type": "session", "id": "tool-envelope", "version": 3],
            ["type": "message", "id": "failed", "message": ["role": "toolResult", "toolCallId": "attempt", "toolName": "exec", "isError": true,
                "content": [["type": "text", "text": "Artificial process output"]]]],
            ["type": "message", "id": "unknown", "message": ["role": "toolResult", "toolCallId": "unknown-attempt",
                "content": [["type": "toolResult", "text": "Artificial output without a status"]]]]
        ], to: url)
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .openClaw, path: url.path)).first)
        let failed = try XCTUnwrap(doc.records.first { $0.id == "tool-envelope:failed" })
        XCTAssertEqual(failed.attributes["is_error"], "true")
        XCTAssertEqual(failed.attributes["tool_name"], "exec")
        XCTAssertEqual(failed.attributes["call_id"], "attempt")
        let unknown = try XCTUnwrap(doc.records.first { $0.id == "tool-envelope:unknown" })
        XCTAssertNil(unknown.attributes["is_error"])
    }

    func testSplitNativeParentAndToolLinksResolveToEvidenceIDs() throws {
        let url = try temporary("split-parent.jsonl")
        try write([
            ["type": "assistant", "sessionId": "split-session", "uuid": "parent", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "An artificial preface"],
                ["type": "tool_use", "id": "native-call", "name": "Read", "input": ["path": "/synthetic"]]
            ]]],
            ["type": "user", "sessionId": "split-session", "uuid": "result", "parentUuid": "parent", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "native-call", "content": "Artificial result"]
            ]]]
        ], to: url)
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .claudeCode, path: url.path)).first)
        let result = try XCTUnwrap(doc.records.first { $0.role == .tool })
        let call = try XCTUnwrap(doc.records.first { $0.kind == "tool_call" })
        XCTAssertEqual(result.attributes["call_id"], "native-call")
        XCTAssertTrue(result.links.contains { $0.relation == "tool_call" && $0.target == call.id })
        XCTAssertEqual(Set(result.links.filter { $0.relation == "parent_record" }.map(\.target)), Set(doc.records.filter { $0.id.contains(":parent:") }.map(\.id)))
    }

    func testMalformedTailCannotAuthorizeReconciliation() throws {
        let url = try temporary("codex.jsonl")
        var data = try Data(contentsOf: fixture("codex.jsonl"))
        data.append(Data("{\"type\":".utf8))
        try data.write(to: url)
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .codex, path: url.path)).first)
        XCTAssertFalse(doc.complete)
        XCTAssertFalse(doc.issues.isEmpty)
        XCTAssertTrue(doc.records.contains { $0.text == "Inspect the artificial build." })
    }

    func testUnknownSessionShapeIsNotAnAuthoritativeEmptyConversation() throws {
        let url = try temporary("history.jsonl")
        try write([["session_id": "one", "ts": 100, "text": "Prompt recall is not a transcript."]], to: url)
        let docs = try SessionAdapters.parse(url: url, source: ImportSource(kind: .codex, path: url.path))
        XCTAssertFalse(docs.isEmpty)
        XCTAssertTrue(docs.allSatisfy { !$0.complete && !$0.issues.isEmpty })
    }

    func testHermesReadsCommittedWALAndPreservesCompactionButExcludesRewind() throws {
        let url = try temporary("state.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try sql(db, "PRAGMA journal_mode=WAL; CREATE TABLE sessions(id TEXT PRIMARY KEY,source TEXT,model TEXT,model_config TEXT,parent_session_id TEXT,started_at REAL,cwd TEXT); CREATE TABLE messages(id INTEGER PRIMARY KEY,session_id TEXT,role TEXT,content TEXT,timestamp REAL,tool_call_id TEXT,tool_calls TEXT,tool_name TEXT,active INTEGER,compacted INTEGER,_compressed_summary INTEGER);")
        try sql(db, "INSERT INTO sessions VALUES('hermes-one','cli','synthetic-model','{\"provider\":\"synthetic-provider\"}',NULL,1,'/synthetic/hermes'); INSERT INTO messages VALUES(1,'hermes-one','user','Original visible history',3,NULL,NULL,NULL,0,1,0); INSERT INTO messages VALUES(2,'hermes-one','assistant','Withdrawn answer',4,NULL,NULL,NULL,0,0,0); INSERT INTO messages VALUES(3,'hermes-one','user','Carried tail',2,NULL,NULL,NULL,0,1,0); INSERT INTO messages VALUES(4,'hermes-one','user','Carried tail',2,NULL,NULL,NULL,1,0,0); INSERT INTO messages VALUES(5,'hermes-one','user','Source summary',5,NULL,NULL,NULL,1,0,1); INSERT INTO messages VALUES(6,'hermes-one','assistant',char(0)||'json:[{\"type\":\"text\",\"text\":\"Structured response\"}]',6,NULL,NULL,NULL,1,0,0);")
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .hermes, path: url.path)).first)
        XCTAssertEqual(doc.id, "hermes-one")
        XCTAssertTrue(doc.complete)
        XCTAssertTrue(doc.records.contains { $0.text == "Original visible history" })
        XCTAssertFalse(doc.records.contains { $0.text.contains("Withdrawn answer") })
        XCTAssertEqual(doc.records.filter { $0.text == "Carried tail" }.count, 1)
        XCTAssertTrue(doc.records.contains { $0.text == "Source summary" && $0.role == .summary })
        XCTAssertTrue(doc.records.contains { $0.text == "Structured response" && $0.provider == "synthetic-provider" })
    }

    func testOpenClawSQLiteRewriteKeepsNativeIdentityAndMetadata() throws {
        let url = try temporary("openclaw-agent.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TABLE session_nodes(session_key TEXT PRIMARY KEY,current_session_id TEXT,entry_json TEXT); CREATE TABLE session_windows(session_id TEXT PRIMARY KEY,session_key TEXT,previous_session_id TEXT,model_provider TEXT,model TEXT,parent_session_key TEXT); CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT,created_at INTEGER,PRIMARY KEY(session_id,seq)); CREATE TABLE transcript_rewrite_watermarks(session_id TEXT PRIMARY KEY,generation TEXT,updated_at INTEGER); INSERT INTO session_nodes VALUES('agent:main:main','claw-sql','{}'); INSERT INTO session_windows VALUES('claw-sql','agent:main:main',NULL,'synthetic-provider','synthetic-model','parent-key'); INSERT INTO transcript_rewrite_watermarks VALUES('claw-sql','g1',1);")
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"claw-sql\",\"cwd\":\"/synthetic/claw\"}"
        let message = "{\"type\":\"message\",\"id\":\"native-event\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"First report\"}]}}"
        try sql(db, "INSERT INTO transcript_events VALUES('claw-sql',0,\(quoted(header)),1); INSERT INTO transcript_events VALUES('claw-sql',1,\(quoted(message)),2);")
        let source = ImportSource(kind: .openClaw, path: url.path)
        let first = try XCTUnwrap(SessionAdapters.parse(url: url, source: source).first?.records.first { $0.text == "First report" })
        try sql(db, "UPDATE transcript_events SET event_json=\(quoted(message.replacingOccurrences(of: "First report", with: "Corrected report"))) WHERE seq=1; UPDATE transcript_rewrite_watermarks SET generation='g2';")
        let second = try XCTUnwrap(SessionAdapters.parse(url: url, source: source).first?.records.first { $0.text == "Corrected report" })
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.provider, "synthetic-provider")
        XCTAssertTrue(second.locator.contains("transcript_events"))
        XCTAssertTrue(second.links.contains { $0.target == "parent-key" })
    }

    func testCodexProjectedSQLiteUpsertsTheSameNativeItem() throws {
        let url = try temporary("thread_history_1.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER,PRIMARY KEY(thread_id,turn_id,item_id)); INSERT INTO thread_items VALUES('codex-db','turn-one','same-item',1,1767225600000,'{\"type\":\"agentMessage\",\"id\":\"same-item\",\"text\":\"An unverified report\",\"phase\":\"final_answer\"}','agentMessage',1);")
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .codex, path: url.path)).first)
        XCTAssertEqual(doc.id, "codex-db")
        XCTAssertTrue(doc.records.contains { $0.text == "An unverified report" && $0.role == .assistant })
    }

    func testExplicitSentientOriginIsMarkedWithoutExcludingCodingProject() throws {
        let url = try temporary("session.jsonl")
        try write([["type":"session_meta","payload":["id":"self-one","originator":"sentient-os","cwd":"/synthetic/work"]], ["type":"response_item","payload":["type":"message","id":"self-item","role":"assistant","content":[["type":"output_text","text":"Generated work"]]]]], to:url)
        let doc = try XCTUnwrap(SessionAdapters.parse(url:url,source:ImportSource(kind:.codex,path:url.path)).first)
        XCTAssertFalse(doc.records.isEmpty)
        XCTAssertTrue(doc.records.allSatisfy { $0.attributes["origin"] == "sentient" })
    }

    func testCodexProjectedSearchEvidenceIsPreservedAndFutureItemsPreventDeletion() throws {
        let url = try temporary("projected.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "projected-one"]],
            ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "Extension", "kind": "web_search", "id": "search-one", "query": "artificial question", "results": [["title": "Artificial page", "url": "https://example.invalid/", "snippet": "Artificial search evidence"]]]]],
            ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "FutureEvidenceType", "id": "future-one", "content": "Future evidence"]]]
        ], to: url)
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .codex, path: url.path)).first)
        XCTAssertTrue(doc.records.contains { $0.role == .tool && $0.text.contains("Artificial search evidence") })
        XCTAssertFalse(doc.complete)
        XCTAssertFalse(doc.issues.isEmpty)
    }

    func testOpenClawDirtyBranchIndexDefersChangesInsteadOfUsingAStaleLeaf() throws {
        let url = try temporary("openclaw-agent.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try sql(db, "CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT); CREATE TABLE session_transcript_index_state(session_id TEXT,leaf_event_id TEXT,needs_rebuild INTEGER); INSERT INTO session_transcript_index_state VALUES('dirty-one','old-leaf',1); INSERT INTO transcript_events VALUES('dirty-one',1,'{\"type\":\"message\",\"id\":\"new-leaf\",\"parentId\":\"old-leaf\",\"message\":{\"role\":\"user\",\"content\":\"New artificial input\"}}');")
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .openClaw, path: url.path)).first)
        XCTAssertFalse(doc.complete)
        XCTAssertTrue(doc.records.isEmpty)
        XCTAssertFalse(doc.issues.isEmpty)
    }

    func testExplicitSessionExportsPreserveNativeSessionsAndBranchRelationships() throws {
        let hermes = try temporary("hermes.jsonl")
        try write([["id": "export-hermes", "source": "cli", "messages": [["id": 1, "role": "user", "content": "Artificial exported prompt", "timestamp": 1]]]], to: hermes)
        let h = try XCTUnwrap(SessionAdapters.parse(url: hermes, source: ImportSource(kind: .hermes, path: hermes.path)).first)
        XCTAssertEqual(h.id, "export-hermes")
        XCTAssertTrue(h.records.contains { $0.role == .user && $0.text == "Artificial exported prompt" })
        let claw = try temporary("session-branch.json")
        let export: [String: Any] = ["header": ["type": "session", "id": "branch-one", "version": 3], "leafId": "new-leaf", "entries": [
            ["type": "message", "id": "old-leaf", "parentId": NSNull(), "message": ["role": "assistant", "content": "Withdrawn artificial branch"]],
            ["type": "message", "id": "new-leaf", "parentId": NSNull(), "message": ["role": "assistant", "content": "Active artificial branch"]]
        ]]
        try JSONSerialization.data(withJSONObject: export).write(to: claw)
        let c = try XCTUnwrap(SessionAdapters.parse(url: claw, source: ImportSource(kind: .openClaw, path: claw.path)).first)
        XCTAssertTrue(c.records.contains { $0.text == "Withdrawn artificial branch" && $0.deleted })
        XCTAssertTrue(c.records.contains { $0.text == "Active artificial branch" && !$0.deleted })
    }

    func testClosedWALDatabaseCanBeReadWithoutCreatingSourceSidecars() throws {
        let url = try temporary("state.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        try sql(db, "PRAGMA journal_mode=WAL; CREATE TABLE sessions(id TEXT,source TEXT); CREATE TABLE messages(id INTEGER,session_id TEXT,role TEXT,content TEXT); INSERT INTO sessions VALUES('closed-wal','cli'); INSERT INTO messages VALUES(1,'closed-wal','user','Artificial closed WAL content');")
        try sql(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        // Apple SQLite may persist empty sidecars after close. Remove them only in this artificial,
        // fully checkpointed fixture to reproduce OpenClaw's observed offline layout.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        let before = try Data(contentsOf: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let doc = try XCTUnwrap(SessionAdapters.parse(url: url, source: ImportSource(kind: .hermes, path: url.path)).first)
        XCTAssertTrue(doc.records.contains { $0.text == "Artificial closed WAL content" })
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }
}
