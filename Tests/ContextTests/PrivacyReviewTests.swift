// Privacy regressions use artificial credentials and paths, never live source data.
import XCTest
@testable import SentientContext

final class PrivacyReviewTests: XCTestCase {
    func testQuotedAndNestedToolCredentialsAreRejectedBeforePersistence() {
        let samples = [
            "export API_KEY=\"synthetic-secret-12345\"",
            "password = \"synthetic-secret-12345\"",
            "{\"access_token\":\"synthetic-secret-12345\"}",
            "{\"cmd\":\"export API_KEY=\\\"synthetic-secret-12345\\\"\"}"
        ]
        for sample in samples {
            XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "synthetic", text: sample)))
            XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "synthetic", text: "Ordinary text", attributes: ["command": sample])))
            XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "synthetic", text: "Ordinary text", links: [EvidenceLink(relation: "evidence", target: sample)])))
        }
    }

    func testSharingRemovesCredentialsAlreadyPresentInOlderStoredText() {
        let shared = EvidencePrivacy.sharingText("Recorded command: API_KEY=\"synthetic-secret-12345\"\nStatus: failed\n")
        XCTAssertFalse(shared.contains("synthetic-secret-12345"))
        XCTAssertTrue(shared.contains("Status: failed"))
        let spaced = EvidencePrivacy.sharingText("password=\"synthetic secret with spaces\"\nStatus: failed")
        XCTAssertFalse(spaced.contains("secret with spaces"))
        let pem = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-KEY-BODY\n-----END PRIVATE KEY-----\nStatus: failed"
        XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "pem", text: pem)))
        XCTAssertFalse(EvidencePrivacy.sharingText(pem).contains("SYNTHETIC-KEY-BODY"))
        XCTAssertTrue(EvidencePrivacy.sharingText(pem).contains("Status: failed"))
    }

    func testSpacedLocalPathsDoNotLeakTrailingNames() {
        for path in ["/Volumes/Synthetic Disk/Private Project/session.jsonl#L2", "/Users/Synthetic User/Private Project/source.md"] {
            let plain = EvidencePrivacy.sharingText("Reference: \(path)\nStatus: failed\n")
            XCTAssertFalse(plain.contains("Private Project"))
            XCTAssertFalse(plain.contains("Synthetic"))
            XCTAssertTrue(plain.contains("Status: failed"))
            let quoted = EvidencePrivacy.sharingText("Reference: \"\(path)\"\nStatus: failed\n")
            XCTAssertFalse(quoted.contains("Private Project"))
            XCTAssertTrue(quoted.contains("Status: failed"))
        }
        let escaped = #"{"cmd":"cat \/Volumes\/Synthetic Disk\/Private Project\/source.md"}"#
        XCTAssertFalse(EvidencePrivacy.sharingText(escaped).contains("Private Project"))
    }

    func testBenignQuotedTextDatesAndNativeMetricValuesSurvive() {
        let text = "Decision: use \"SQLite\".\n2026-09-06: 0 steps; mood 4 /5."
        XCTAssertEqual(EvidencePrivacy.sanitize(EvidenceRecord(id: "safe", text: text))?.text, text)
        XCTAssertEqual(EvidencePrivacy.sharingText(text), text)
        XCTAssertNil(EvidencePrivacy.sanitize(EvidenceRecord(id: "metadata", text: "Ordinary", attributes: ["password": "synthetic-secret-12345"])))
    }
}
