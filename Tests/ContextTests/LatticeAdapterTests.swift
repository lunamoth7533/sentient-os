import Foundation
import XCTest
@testable import SentientContext

final class LatticeAdapterTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Lattice", isDirectory: true)
    }
    private func source(_ url: URL, kind: ImportSourceKind = .lattice) -> ImportSource {
        ImportSource(id: "synthetic-source", kind: kind, path: url.path)
    }
    private func capsuleObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot.appendingPathComponent("capsule.json"))) as? [String: Any])
    }
    private func snapshotObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot.appendingPathComponent("personal-snapshot.json"))) as? [String: Any])
    }
    private func withFile(_ data: Data, extension suffix: String = "json", _ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-lattice-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.\(suffix)")
        try data.write(to: url)
        try run(url)
    }
    private func rejectJSON(_ object: [String: Any]) throws {
        try withFile(JSONSerialization.data(withJSONObject: object)) { url in
            XCTAssertThrowsError(try LatticeAdapter.parse(url: url, source: source(url)))
        }
    }

    func testCapsuleSummariesRetainProjectAttributionAndOmissionsWithoutDeletingOlderEvidence() throws {
        let url = fixtureRoot.appendingPathComponent("capsule.json")
        let document = try XCTUnwrap(LatticeAdapter.parse(url: url, source: source(url)).first)
        XCTAssertTrue(document.complete)
        XCTAssertFalse(document.replaceExisting)
        let event = try XCTUnwrap(document.records.first { $0.id == "project:synthetic-project:event:test-1" })
        XCTAssertEqual(event.role, .summary)
        XCTAssertEqual(event.project, "synthetic-project")
        XCTAssertEqual(event.sessionID, "thread-1")
        XCTAssertEqual(event.attributes["status"], "succeeded")
        XCTAssertEqual(event.links, [EvidenceLink(relation: "evidence", target: "test:synthetic-1")])
        XCTAssertEqual(event.attributes["revisionTimestamp"], "2026-09-06T12:00:00.000Z")
        XCTAssertTrue(document.records.contains { $0.text.contains("Two older work events omitted") })
        XCTAssertTrue(document.records.contains { $0.text.contains("Run a physical-device check.") })
    }

    func testCapsuleRejectsProjectBoundaryViolationUnknownSchemaAndDuplicateIDs() throws {
        var object = try capsuleObject()
        var events = try XCTUnwrap(object["events"] as? [[String: Any]])
        events[0]["projectID"] = "other-project"
        object["events"] = events
        try rejectJSON(object)
        object = try capsuleObject(); object["schema"] = "lattice.context-capsule.v99"
        try rejectJSON(object)
        object = try capsuleObject()
        events = try XCTUnwrap(object["events"] as? [[String: Any]])
        object["events"] = events + events
        try rejectJSON(object)
    }

    func testCapsuleBoundsAndRequiredArraysFailClosed() throws {
        var object = try capsuleObject(); object["goal"] = String(repeating: "x", count: 8_193)
        try rejectJSON(object)
        object = try capsuleObject(); object.removeValue(forKey: "redactions")
        try rejectJSON(object)
        object = try capsuleObject()
        var event = try XCTUnwrap((object["events"] as? [[String: Any]])?.first)
        object["events"] = (0...500).map { index -> [String: Any] in event["id"] = "event-\(index)"; return event }
        try rejectJSON(object)
        object = try capsuleObject(); object["unrecognizedPadding"] = String(repeating: "x", count: 1_048_576)
        try rejectJSON(object)
    }

    func testCapsuleRejectsAnIdentifierWithATrailingNewline() throws {
        var object = try capsuleObject(); object["id"] = "capsule-with-newline\n"
        try rejectJSON(object)
    }

    func testEqualTimeCapsuleCorrectionDoesNotSortByUnrelatedCapsuleIdentity() throws {
        var original = try capsuleObject(); original["id"] = "z-first-capsule"
        try withFile(JSONSerialization.data(withJSONObject: original)) { url in
            let store = try EvidenceStore(url: url.deletingLastPathComponent().appendingPathComponent("evidence.sqlite"))
            let selected = source(url)
            try store.saveSource(selected)
            try store.commit(sourceID: selected.id, fileID: url.path, fingerprint: "first",
                             documents: LatticeAdapter.parse(url: url, source: selected))
            var corrected = original; corrected["id"] = "a-correcting-capsule"
            var events = try XCTUnwrap(corrected["events"] as? [[String: Any]])
            events[0]["summary"] = "Corrected same-time source summary."
            corrected["events"] = events
            try JSONSerialization.data(withJSONObject: corrected).write(to: url)
            try store.commit(sourceID: selected.id, fileID: url.path, fingerprint: "corrected",
                             documents: LatticeAdapter.parse(url: url, source: selected))
            let event = try XCTUnwrap(store.evidence(audience: .local).first { $0.record.attributes["nativeKind"] == "test" })
            XCTAssertTrue(event.record.text.contains("Corrected same-time source summary."))
        }
    }

    func testProjectAndEventIdentifiersCannotCollideThroughColonConcatenation() throws {
        var a = try capsuleObject(), b = try capsuleObject()
        a["project"] = ["id": "a:event:b", "name": "A", "aliases": []] as [String: Any]
        b["project"] = ["id": "a", "name": "B", "aliases": []] as [String: Any]
        var eventA = try XCTUnwrap((a["events"] as? [[String: Any]])?.first)
        var eventB = eventA
        eventA["projectID"] = "a:event:b"; eventA["id"] = "c"
        eventB["projectID"] = "a"; eventB["id"] = "b:event:c"
        a["events"] = [eventA]; a["releases"] = []
        b["events"] = [eventB]; b["releases"] = []
        var ids: [String] = []
        for object in [a, b] {
            try withFile(JSONSerialization.data(withJSONObject: object)) { url in
                let records = try LatticeAdapter.parse(url: url, source: source(url)).flatMap(\.records)
                ids.append(try XCTUnwrap(records.first { $0.attributes["status"] == "succeeded" }).id)
            }
        }
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testPersonalSnapshotKeepsNativeRevisionCivilDayZeroAndAbsentOptionalValues() throws {
        let url = fixtureRoot.appendingPathComponent("personal-snapshot.json")
        let document = try XCTUnwrap(LatticeAdapter.parse(url: url, source: source(url)).first)
        XCTAssertTrue(document.complete)
        XCTAssertTrue(document.replaceExisting)
        XCTAssertEqual(document.records.count, 3)
        XCTAssertTrue(document.records.allSatisfy(\.sensitive))
        let checkIn = try XCTUnwrap(document.records.first { $0.id == "checkin-2026-09-06" })
        XCTAssertEqual(checkIn.timestamp, "2026-09-06")
        XCTAssertNil(checkIn.occurredAt)
        XCTAssertEqual(checkIn.attributes["timezone"], "unknown")
        XCTAssertEqual(checkIn.attributes["revisionTimestamp"], "2026-09-06T12:00:00.125Z")
        XCTAssertEqual(checkIn.attributes["revision"], "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(checkIn.attributes["caffeineMg"], "0")
        XCTAssertNil(checkIn.attributes["energyLevel"])
        let steps = try XCTUnwrap(document.records.first { $0.id == "metric-steps-2026-09-06" })
        XCTAssertEqual(steps.attributes["value"], "0")
        XCTAssertEqual(steps.attributes["unit"], "steps")
        XCTAssertEqual(steps.attributes["availability"], "recorded")
        let deleted = try XCTUnwrap(document.records.first { $0.deleted })
        XCTAssertEqual(deleted.id, "metric-sleepHours-2026-09-05")
        XCTAssertTrue(deleted.text.isEmpty)
        XCTAssertNil(deleted.attributes["value"])
        let encoded = String(decoding: try JSONEncoder().encode(document.records), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-account-never-import"))
        XCTAssertFalse(encoded.contains("changeToken"))
        XCTAssertFalse(encoded.contains("pending"))
    }

    func testPersonalSnapshotRejectsWrongEpochTypeMismatchedIDsInvalidDaysRatingsAndTombstoneValues() throws {
        for field in ["updatedAt", "id", "day", "checkIn", "deleted"] {
            var object = try snapshotObject()
            var records = try XCTUnwrap(object["records"] as? [String: [String: Any]])
            var record = try XCTUnwrap(records["checkin-2026-09-06"])
            switch field {
            case "updatedAt": record[field] = "2026-09-06T12:00:00Z"
            case "id": record[field] = "checkin-2026-09-05"
            case "day": record[field] = "2026-02-30"
            case "checkIn": record[field] = ["day": "2026-09-06", "mood": 0]
            default: record[field] = true
            }
            records["checkin-2026-09-06"] = record; object["records"] = records
            try rejectJSON(object)
        }
        var object = try snapshotObject(); object["version"] = 2
        try rejectJSON(object)
    }

    func testPersonalAggregateRejectsUnknownMetricNegativeValuesAndInvalidUUIDRevision() throws {
        for field in ["metric", "value", "revision"] {
            var object = try snapshotObject()
            var records = try XCTUnwrap(object["records"] as? [String: [String: Any]])
            var record = try XCTUnwrap(records["metric-steps-2026-09-06"])
            record[field] = field == "value" ? -1 : (field == "metric" ? "inventedMetric" : "not-a-uuid")
            records["metric-steps-2026-09-06"] = record; object["records"] = records
            try rejectJSON(object)
        }
    }

    func testCSVPreservesQuotedMultilineSourceUnknownValueAndDeletion() throws {
        let url = fixtureRoot.appendingPathComponent("metrics.csv")
        let document = try XCTUnwrap(MetricsCSVAdapter.parse(url: url, source: source(url, kind: .metricsCSV)).first)
        XCTAssertEqual(document.records.count, 3)
        XCTAssertTrue(document.records.allSatisfy(\.sensitive))
        let steps = try XCTUnwrap(document.records.first { $0.id == "day-steps" })
        XCTAssertEqual(steps.attributes["value"], "0")
        XCTAssertEqual(steps.provider, "Synthetic, watch")
        XCTAssertEqual(steps.attributes["timezone"], "unknown")
        XCTAssertEqual(steps.attributes["revisionTimestamp"], "2026-09-06T12:00:00.125Z")
        let sleep = try XCTUnwrap(document.records.first { $0.id == "day-sleep" })
        XCTAssertNil(sleep.attributes["value"])
        XCTAssertEqual(sleep.attributes["availability"], "unknown")
        XCTAssertEqual(sleep.provider, "Synthetic\nsleep log")
        XCTAssertEqual(sleep.timestamp, "2026-09-06")
        XCTAssertNil(sleep.occurredAt)
        XCTAssertTrue(try XCTUnwrap(document.records.first { $0.id == "old-step" }).deleted)
    }

    func testCSVRequiresExactHeadersFiniteNumbersValidDatesAndCompleteQuotes() throws {
        let header = "id,metric,value,unit,date,timezone,updated_at,deleted,source\n"
        let row = "one,steps,1,steps,2026-09-06,UTC,2026-09-06T12:00:00Z,false,Manual\n"
        let invalid = [
            header.replacingOccurrences(of: "updated_at", with: "updatedAt") + row,
            header + row.replacingOccurrences(of: ",1,", with: ",NaN,"),
            header + row.replacingOccurrences(of: ",1,", with: ",Infinity,"),
            header + row.replacingOccurrences(of: "2026-09-06,UTC", with: "2026-02-30,UTC"),
            header + row.replacingOccurrences(of: ",UTC,", with: ",Made/Up,"),
            header + row.replacingOccurrences(of: "false,Manual", with: "true,Manual"),
            header + row.replacingOccurrences(of: "Manual", with: "\"unfinished"),
            header + row + row
        ]
        for text in invalid {
            try withFile(Data(text.utf8), extension: "csv") { url in
                XCTAssertThrowsError(try MetricsCSVAdapter.parse(url: url, source: source(url, kind: .metricsCSV)))
            }
        }
    }

    func testCSVHandlesCRLFEscapedQuotesAndTimestampedCorrectionsWithoutChangingIdentity() throws {
        let header = "id,metric,value,unit,date,timezone,updated_at,deleted,source\r\n"
        var records: [EvidenceRecord] = []
        for (value, timestamp) in [("3", "2026-09-06T12:00:00Z"), ("4", "2026-09-06T12:00:00.001Z")] {
            let text = header + "same,mood,\(value),/5,2026-09-06T08:00:00-05:00,America/Chicago,\(timestamp),false,\"Manual \"\"check-in\"\"\"\r\n"
            try withFile(Data(text.utf8), extension: "csv") { url in
                records.append(try XCTUnwrap(MetricsCSVAdapter.parse(url: url, source: source(url, kind: .metricsCSV)).first?.records.first))
            }
        }
        XCTAssertEqual(records[0].id, records[1].id)
        XCTAssertEqual(records[0].provider, "Manual \"check-in\"")
        XCTAssertEqual(records[1].attributes["value"], "4")
        XCTAssertNotNil(records[1].occurredAt)
        XCTAssertEqual(records[1].attributes["revisionTimestamp"], "2026-09-06T12:00:00.001Z")
    }
}
