import XCTest
@testable import agentacct

final class SetupCaptureObserverTests: XCTestCase {
    private func detail(client: String = "codex", step: [String: Any]) throws -> V1SessionDetail {
        let payload: [String: Any] = [
            "schema": "agentacct.v1-session-detail.v1",
            "session": ["client": client, "client_session_id": "session-1", "last_activity_at": 9_999],
            "steps": [step], "descendants": []
        ]
        return try JSONDecoder().decode(V1SessionDetail.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    func testNewSectionEventConfirmsOnlyTheSelectedClientAndBoundary() throws {
        let record = try detail(step: ["section_id": "s1", "latest_event_id": "evt-new", "updated_at": 1_001])
        let boundary = Date(timeIntervalSince1970: 1_000)
        let capture = SetupCaptureObserver.confirmation(in: record, client: .codex, after: boundary)
        XCTAssertEqual(capture?.eventID, "evt-new")
        XCTAssertEqual(capture?.observedAt, Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(capture?.clientSessionID, "session-1")
        XCTAssertEqual(capture?.sessionKey, "codex::session-1")
        XCTAssertNil(SetupCaptureObserver.confirmation(in: record, client: .claudeCode, after: boundary))
        XCTAssertNil(SetupCaptureObserver.confirmation(in: record, client: .codex, after: Date(timeIntervalSince1970: 1_001)))
    }

    func testRecencyAndUnidentifiedSectionNeverConfirmCapture() throws {
        let record = try detail(step: ["section_id": "s1", "updated_at": 1_001])
        XCTAssertNil(SetupCaptureObserver.confirmation(in: record, client: .codex, after: Date(timeIntervalSince1970: 1_000)))
    }

    func testOlderDaemonCanConfirmAnIdentifiedFreshMachineCheck() throws {
        let record = try detail(step: ["checks": [["event_id": "evt-check", "created_at": 1_010, "result": "failed"]]])
        let capture = SetupCaptureObserver.confirmation(in: record, client: .codex, after: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(capture?.eventID, "evt-check")
        // Even a failing check proves capture; it does not prove success.
    }
}
