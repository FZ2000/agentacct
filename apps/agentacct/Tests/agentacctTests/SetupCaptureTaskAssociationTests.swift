import XCTest
@testable import agentacct

final class SetupCaptureTaskAssociationTests: XCTestCase {
    private let boundary = Date(timeIntervalSince1970: 1_000)

    func testLaterTaskListEnrichesConfirmedCaptureWithoutChangingEvidence() throws {
        let capture = confirmation()
        var history = RecordingConnectionHistory()
        history.configured(.codex, at: boundary)
        history.observed(capture)
        XCTAssertTrue(history.pending.isEmpty)
        XCTAssertFalse(history.enrichTaskAssociations { _ in nil })
        XCTAssertEqual(history.captures["codex"], capture)

        let associations = SetupCaptureTaskResolver.associations(tasks: [try task("task-1")], receipts: [])
        XCTAssertTrue(history.enrichTaskAssociations {
            SetupCaptureTaskResolver.taskID(for: $0, associations: associations)
        })

        XCTAssertEqual(history.captures["codex"]?.taskID, "task-1")
        XCTAssertEqual(history.captures["codex"]?.eventID, capture.eventID)
        XCTAssertEqual(history.captures["codex"]?.observedAt, capture.observedAt)
        XCTAssertEqual(history.captures["codex"]?.clientSessionID, capture.clientSessionID)
        XCTAssertEqual(history.captures["codex"]?.sessionKey, capture.sessionKey)
        XCTAssertEqual(history.boundaries["codex"], boundary)
        XCTAssertTrue(history.pending.isEmpty)
        XCTAssertFalse(history.enrichTaskAssociations { _ in "other-task" })
        XCTAssertEqual(history.captures["codex"]?.taskID, "task-1")
    }

    func testChildSessionAssociatesOnlyWhenLoadedReceiptListsIt() throws {
        let capture = confirmation(sessionID: "child-session")
        let tasks = [try task("task-parent", sessionID: "parent-session")]
        XCTAssertNil(SetupCaptureTaskResolver.taskID(for: capture, associations:
            SetupCaptureTaskResolver.associations(tasks: tasks, receipts: [])))

        let receipt = try receipt(taskID: "task-parent", rootID: "parent-session", memberID: "child-session")
        let associations = SetupCaptureTaskResolver.associations(tasks: tasks, receipts: [receipt])

        XCTAssertEqual(SetupCaptureTaskResolver.taskID(for: capture, associations: associations), "task-parent")
        XCTAssertEqual(associations.count, 2)
    }

    func testAmbiguousRootsAndConflictingReceiptMembershipDoNotChooseFirstMatch() throws {
        let capture = confirmation()
        let ambiguous = SetupCaptureTaskResolver.associations(
            tasks: [try task("task-a"), try task("task-b")], receipts: []
        )
        XCTAssertNil(SetupCaptureTaskResolver.taskID(for: capture, associations: ambiguous))

        let conflict = SetupCaptureTaskResolver.associations(tasks: [try task("task-a")], receipts: [
            try receipt(taskID: "task-b", rootID: "other-root", memberID: "session-1")
        ])
        XCTAssertNil(SetupCaptureTaskResolver.taskID(for: capture, associations: conflict))
    }

    func testAssociationRequiresExactClientAndConsistentSessionIdentity() throws {
        let associations = SetupCaptureTaskResolver.associations(tasks: [try task("task-1")], receipts: [])
        let wrongClient = SetupCaptureConfirmation(clientID: "claude-code", eventID: "evt", observedAt: boundary,
            taskID: nil, clientSessionID: "session-1", sessionKey: "claude-code::session-1")
        let conflictingIdentity = SetupCaptureConfirmation(clientID: "codex", eventID: "evt", observedAt: boundary,
            taskID: nil, clientSessionID: "session-1", sessionKey: "codex::another-session")
        let unidentified = SetupCaptureConfirmation(clientID: "codex", eventID: "session-1", observedAt: boundary,
            taskID: nil)

        XCTAssertNil(SetupCaptureTaskResolver.taskID(for: wrongClient, associations: associations))
        XCTAssertNil(SetupCaptureTaskResolver.taskID(for: conflictingIdentity, associations: associations))
        XCTAssertNil(SetupCaptureTaskResolver.taskID(for: unidentified, associations: associations))
    }

    func testLegacyHistoryDecodesAndRemainsConfirmedWithoutInventingSessionIdentity() throws {
        let json = """
        {"boundaries":{"codex":1000},"captures":{"codex":{"clientID":"codex","eventID":"evt-old","observedAt":1001,"taskID":null}}}
        """
        var history = try JSONDecoder().decode(RecordingConnectionHistory.self, from: Data(json.utf8))

        XCTAssertTrue(history.pending.isEmpty)
        XCTAssertEqual(history.captures["codex"]?.eventID, "evt-old")
        XCTAssertNil(history.captures["codex"]?.clientSessionID)
        XCTAssertNil(history.captures["codex"]?.sessionKey)
        XCTAssertFalse(history.enrichTaskAssociations { _ in "unproven-task" })
        XCTAssertNil(history.captures["codex"]?.taskID)
    }

    func testEnrichmentOfEarlierCaptureDoesNotClearLaterPendingReconfiguration() throws {
        var history = RecordingConnectionHistory()
        history.configured(.codex, at: boundary)
        history.observed(confirmation())
        let laterBoundary = boundary.addingTimeInterval(10)
        history.configured(.codex, at: laterBoundary)

        XCTAssertTrue(history.enrichTaskAssociations { _ in "task-original" })

        XCTAssertEqual(history.pending["codex"], laterBoundary)
        XCTAssertEqual(history.captures["codex"]?.observedAt, boundary.addingTimeInterval(1))
        let roundTrip = try JSONDecoder().decode(RecordingConnectionHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(roundTrip, history)
        XCTAssertEqual(roundTrip.captures["codex"]?.exactSessionKey, "codex::session-1")
    }

    private func confirmation(sessionID: String = "session-1") -> SetupCaptureConfirmation {
        .init(clientID: "codex", eventID: "evt-confirmed", observedAt: boundary.addingTimeInterval(1), taskID: nil,
              clientSessionID: sessionID, sessionKey: "codex::\(sessionID)")
    }

    private func task(_ id: String, sessionID: String = "session-1") throws -> ReceiptSummary {
        try decode([
            "task_id": id,
            "decision_status": ["key": "completed"], "evidence_strength": ["key": "recorded"], "cost": [:],
            "primary_root": ["client": "codex", "client_session_id": sessionID]
        ])
    }

    private func receipt(taskID: String, rootID: String, memberID: String) throws -> Receipt {
        try decode([
            "schema_version": "agentacct.receipt.v1", "task_id": taskID,
            "axes": ["decision_status": ["key": "completed"], "evidence_strength": ["key": "recorded"]],
            "dimensions": ["task": [:], "actors": [:], "actions": [:], "cost": [:], "evidence": [:],
                           "outcome": [:], "gaps": [:], "provenance": [:]],
            "sessions": [["root": ["client": "codex", "client_session_id": rootID],
                          "members": [["client": "codex", "client_session_id": memberID]]]]
        ])
    }

    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
