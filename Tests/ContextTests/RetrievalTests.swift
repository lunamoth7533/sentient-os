// The fixed pre-change evaluation corpus is shared by all retrieval variants.
import XCTest
@testable import SentientContext

final class RetrievalTests: XCTestCase {
    func testTooSmallBudgetDoesNotClaimMatchingEvidenceIsMissing() throws {
        let source = ImportSource(id: "s", kind: .codex, path: "/synthetic")
        let evidence = [StoredEvidence(source: source, record: EvidenceRecord(id: "r", text: "Decision: preserve the existing vault.", role: .user))]
        let result = try ContextRetriever.retrieve(evidence: evidence, query: ContextQuery(text: "decision", tokenBudget: 128), audience: .local)
        XCTAssertTrue(result.citations.isEmpty)
        XCTAssertEqual(result.omitted, 1)
        XCTAssertTrue(result.text.contains("Evidence found; raise budget."))
        XCTAssertLessThanOrEqual(result.text.utf8.count, 128)
    }
    func testEvaluationSourcesRetainTheirNativeKinds() throws {
        let corpus = try evaluationCorpus()
        XCTAssertEqual(Set(corpus.records.filter { $0.record.project == "lattice-demo" }.map(\.source.kind)), [.lattice])
        XCTAssertEqual(Set(corpus.records.filter { $0.record.project != "lattice-demo" }.map(\.source.kind)), [.codex])
    }
    func testProjectAnchorDoesNotFillBudgetWithUnrelatedProjectFacts() throws {
        let source = ImportSource(id: "s", kind: .codex, path: "/synthetic")
        let records = [EvidenceRecord(id: "relevant", text: "Atlas storage decision: SQLite", project: "/work/atlas"),
                       EvidenceRecord(id: "irrelevant", text: "Atlas launch date is Monday", project: "/work/atlas")]
        let result = try ContextRetriever.retrieve(evidence: records.map { StoredEvidence(source: source, record: $0) }, query: ContextQuery(text: "Atlas storage decision", project: "/work/atlas"), audience: .local)
        XCTAssertEqual(result.citations.map(\.recordID), ["relevant"])
    }
    func testToolFailureAndModelMetadataRemainVisible() throws {
        let source = ImportSource(id: "x", kind: .codex, path: "/synthetic/session")
        let r = EvidenceRecord(id: "patch", text: "apply_patch: update app.swift", role: .tool,
            provider: "openai", model: "recorded-model", application: "Codex",
            attributes: ["status": "failed", "exit_code": "1", "is_error": "true"])
        let evidence = [StoredEvidence(source: source, record: r)]
        let result = try ContextRetriever.retrieve(evidence: evidence, query: ContextQuery(text: "patch"), audience: .local)
        let projection = try ContextProjection.notes(evidence: evidence, audience: .local).values.joined()
        for text in [result.text, projection] {
            XCTAssertTrue(text.contains("status=failed"))
            XCTAssertTrue(text.contains("exit_code=1"))
            XCTAssertTrue(text.contains("is_error=true"))
            XCTAssertTrue(text.contains("recorded-model"))
        }
    }
    func testFixedQueriesHaveCitedSupportWithinBudget() throws {
        let corpus = try evaluationCorpus()
        for query in corpus.queries {
            let result = try ContextRetriever.retrieve(evidence: corpus.records, query: query.query, audience: .local)
            XCTAssertLessThanOrEqual(result.text.utf8.count, query.query.tokenBudget)
            let ids = Set(result.citations.map(\.recordID))
            for id in query.required { XCTAssertTrue(ids.contains(id), "\(query.id) omitted \(id): \(result.text)") }
            for id in query.forbidden { XCTAssertFalse(ids.contains(id), "\(query.id) leaked \(id)") }
        }
    }
    func testAssistantProposalNeverBecomesConfirmedWork() throws {
        let source = ImportSource(id: "x", kind: .codex, path: "/tmp/x")
        let result = try ContextRetriever.retrieve(evidence: [StoredEvidence(source: source, record: EvidenceRecord(id: "p", text: "I suggest deploying on Friday", role: .assistant))], query: ContextQuery(text: "deploy Friday"), audience: .local)
        XCTAssertTrue(result.text.contains("unverified"))
    }
    func testPermissionsApplyBeforeRankingAndGraphExpansion() throws {
        let corpus = try evaluationCorpus()
        let result = try ContextRetriever.retrieve(evidence: corpus.records, query: ContextQuery(text: "Atlas", includeGraph: true), audience: .shared)
        XCTAssertTrue(result.citations.isEmpty)
        XCTAssertFalse(result.text.contains("SQLite"))
    }
    func testEmptyQueryAndInvalidBudgetAreActionable() throws {
        XCTAssertThrowsError(try ContextRetriever.retrieve(evidence: [], query: ContextQuery(text: " "), audience: .local))
        XCTAssertThrowsError(try ContextRetriever.retrieve(evidence: [], query: ContextQuery(text: "work", tokenBudget: 0), audience: .local))
    }
    func testUnicodeBudgetAndDuplicateSuppression() throws {
        let source = ImportSource(id: "x", kind: .markdown, path: "/tmp/x")
        let value = EvidenceRecord(id: "a", text: "工作 " + String(repeating: "知识", count: 500), project: "p")
        var duplicate = value; duplicate.id = "b"
        let result = try ContextRetriever.retrieve(evidence: [StoredEvidence(source: source, record: value), StoredEvidence(source: source, record: duplicate)], query: ContextQuery(text: "工作", tokenBudget: 512), audience: .local)
        XCTAssertLessThanOrEqual(result.text.utf8.count, 512)
        XCTAssertEqual(result.citations.count, 1)
    }
    func testFixedEvaluationReport() throws {
        guard let output = ProcessInfo.processInfo.environment["SENTIENT_EVAL_OUTPUT"] else { return }
        let corpus = try evaluationCorpus()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-fixed-evaluation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        for group in Dictionary(grouping: corpus.records, by: { $0.source.id }).values {
            let source = group[0].source
            try store.saveSource(source)
            try store.commit(sourceID: source.id, fileID: "frozen-corpus", fingerprint: "frozen-v1",
                             documents: [ImportDocument(id: "frozen-corpus", records: group.map(\.record))])
        }
        var rows: [[String: Any]] = []
        for expansion in [false, true] {
            for item in corpus.queries {
                var query = item.query; query.includeGraph = expansion
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try ContextRetriever.retrieve(store: store, query: query, audience: .local)
                let ids = Set(result.citations.map(\.recordID))
                rows.append(["id": item.id, "variant": expansion ? "lexical-plus-graph" : "lexical", "context": result.text,
                    "retrievedEvidenceIDs": result.citations.map(\.recordID), "required": item.required,
                    "importantOmissions": item.required.filter { !ids.contains($0) },
                    "forbiddenHits": item.forbidden.filter { ids.contains($0) },
                    "citationAccuracy": result.citations.allSatisfy { cite in corpus.records.contains { $0.id == cite.id && $0.record.id == cite.recordID } },
                    "bytes": result.text.utf8.count, "budget": query.tokenBudget,
                    "latencyMS": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000])
            }
        }
        try JSONSerialization.data(withJSONObject: ["path": "production EvidenceStore and ContextRetriever; import/setup excluded from latency", "outputs": rows], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}

private struct EvaluationQuery { var id: String; var query: ContextQuery; var required: [String]; var forbidden: [String] }
private func evaluationCorpus() throws -> (records: [StoredEvidence], queries: [EvaluationQuery]) {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/ContextEvaluation/corpus.json")
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    let records = (fixture["records"] as! [[String: String]]).map { r in
        let kind: ImportSourceKind = r["project"] == "lattice-demo" ? .lattice : .codex
        let source = ImportSource(id: "fixed-evaluation-" + kind.rawValue, kind: kind, path: "/synthetic/evaluation/" + kind.rawValue)
        return StoredEvidence(source: source, record: EvidenceRecord(id: r["id"]!, text: r["text"]!, role: EvidenceRole(rawValue: r["role"]!)!, kind: r["kind"]!, sessionID: r["session"], project: r["project"], timestamp: r["date"], locator: "fixture:" + r["id"]!))
    }
    let queries = (fixture["queries"] as! [[String: Any]]).map { q in EvaluationQuery(id: q["id"] as! String, query: ContextQuery(text: q["query"] as! String, project: q["project"] as? String, tokenBudget: fixture["budget"] as! Int), required: q["required"] as! [String], forbidden: q["forbidden"] as! [String]) }
    return (records, queries)
}
