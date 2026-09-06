// Behavioral contracts for the local context store, evaluated over artificial data only.
import XCTest
@testable import SentientContext

final class ContextTests: XCTestCase {
    func testSourceDefaultsRequireExplicitSharing() {
        let source = ImportSource(kind: .codex, path: "/synthetic/sessions")
        XCTAssertTrue(source.enabled)
        XCTAssertTrue(source.contextEnabled)
        XCTAssertFalse(source.shareEnabled)
    }

    func testRolesDoNotConflateProposalsAndEvidence() {
        XCTAssertNotEqual(EvidenceRole.user, EvidenceRole.assistant)
        XCTAssertNotEqual(EvidenceRole.assistant, EvidenceRole.tool)
    }

    func testCivilDateIsNotInventedAsAnInstant() {
        XCTAssertNil(EvidenceDates.parse("2026-09-06"))
        XCTAssertNotNil(EvidenceDates.parse("2026-09-06T12:00:00Z"))
    }
}
