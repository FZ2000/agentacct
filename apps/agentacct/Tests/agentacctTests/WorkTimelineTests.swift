import XCTest
@testable import agentacct

final class WorkTimelineTests: XCTestCase {
    func testChronologyUsesSourceTimeWithStableTiesAndUndatedOutsideAxis() {
        let projection = WorkTimelineProjection(records: [
            record("undated"), record("later", time: 30), record("b", time: 10), record("a", time: 10),
        ])
        XCTAssertEqual(projection.records.map(\.id), ["a", "b", "later", "undated"])
        XCTAssertEqual(projection.interval, WorkTimelineInterval(lower: 9, upper: 31))
        XCTAssertTrue(WorkTimelineInterval(lower: 20, upper: 25).contains(record("undated")))
        XCTAssertFalse(WorkTimelineInterval(lower: 20, upper: 25).contains(record("a", time: 10)))
    }

    func testDurationRequiresValidBoundsAndNamesClockInconsistency() {
        let duration = WorkTimelineProjection.stepBounds(start: 10, update: 30)
        XCTAssertEqual(duration.start, 10)
        XCTAssertEqual(duration.end, 30)
        XCTAssertTrue(duration.note.contains("not execution duration"))
        let inverted = WorkTimelineProjection.stepBounds(start: 30, update: 10)
        XCTAssertNil(inverted.end)
        XCTAssertTrue(inverted.note.contains("inconsistent"))
        let point = WorkTimelineProjection.stepBounds(start: nil, update: 20)
        XCTAssertEqual(point.start, 20)
        XCTAssertNil(point.end)
        XCTAssertNil(WorkTimelineProjection.validTime(.nan))
        XCTAssertNil(WorkTimelineProjection.validTime(.infinity))
        XCTAssertNil(WorkTimelineProjection.validTime(0))
    }

    func testDedupRequiresImmutableEventIdentity() {
        var first = record("first", time: 10)
        first.eventID = "event-1"
        var duplicate = first
        duplicate.id = "duplicate"
        let anonymousA = record("anonymous-a", time: 10)
        let anonymousB = record("anonymous-b", time: 10)
        let projection = WorkTimelineProjection(records: [first, duplicate, anonymousA, anonymousB])
        XCTAssertEqual(projection.records.count, 3)
        XCTAssertEqual(projection.records.filter { $0.eventID == "event-1" }.count, 1)
        XCTAssertEqual(projection.records.filter { $0.eventID == nil }.count, 2)
    }

    func testLaterPassDoesNotClearUnrelatedFailure() {
        var failure = record("failed", time: 10)
        failure.result = "failed"
        failure.eventID = "failure-event"
        var passed = record("passed", time: 20)
        passed.result = "passed"
        passed.eventID = "pass-event"
        let projection = WorkTimelineProjection(records: [failure, passed])
        XCTAssertTrue(failure.isCurrentFailure)
        XCTAssertTrue(projection.relationship(failure, passed).contains("No direct event relationship"))
        failure.superseded = true
        failure.supersededBy = "pass-event"
        XCTAssertFalse(failure.isCurrentFailure)
        XCTAssertEqual(failure.result, "failed")
        XCTAssertTrue(projection.relationship(failure, passed).contains("Recorded supersession"))
    }

    func testHeldFeedPreservesSelectedPayloadAndCountsRevisionsOnce() {
        let first = record("first", time: 20)
        var feed = WorkTimelineFeed()
        feed.ingest(WorkTimelineProjection(records: [first]), following: true)
        var revised = first
        revised.summary = "New detail"
        let late = record("late-arrival", time: 10)
        let next = WorkTimelineProjection(records: [revised, late])
        feed.ingest(next, following: false)
        feed.ingest(next, following: false)
        XCTAssertEqual(feed.pendingIDs, ["first", "late-arrival"])
        XCTAssertNil(feed.visible.records.first?.summary)
        XCTAssertEqual(feed.visible.records.count, 1)
        feed.reveal()
        XCTAssertTrue(feed.pendingIDs.isEmpty)
        XCTAssertEqual(feed.visible.records.map(\.id), ["late-arrival", "first"])
        XCTAssertEqual(feed.visible.records.last?.summary, "New detail")
    }

    func testRemovedRecordRemainsHeldUntilExplicitReveal() {
        var feed = WorkTimelineFeed()
        feed.ingest(WorkTimelineProjection(records: [record("saved", time: 10)]), following: true)
        feed.ingest(.empty, following: false)
        XCTAssertEqual(feed.visible.records.map(\.id), ["saved"])
        XCTAssertEqual(feed.pendingIDs, ["saved"])
        feed.reveal()
        XCTAssertTrue(feed.visible.records.isEmpty)
    }

    func testNestedArrivalInspectionKeepsOriginalHistoryBookmark() {
        var state = WorkTimelineNavigation()
        state.view.selectedID = "original"
        state.view.query = "test.swift"
        state.view.file = "Sources/test.swift"
        state.view.compareIDs = ["a", "b"]
        state.view.anchorID = "anchor"
        state.view.interval = WorkTimelineInterval(lower: 10, upper: 20)
        let original = state.view
        state.beginArrivals()
        state.view.selectedID = "arrival-a"
        state.beginArrivals()
        state.view.selectedID = "arrival-b"
        XCTAssertEqual(state.history, original)
        state.returnToHistory()
        XCTAssertEqual(state.view, original)
        XCTAssertNil(state.history)
        XCTAssertFalse(state.following)
    }

    @MainActor func testPreferencesRemainTaskScopedAndDoNotPersistEvidence() throws {
        let suite = "WorkTimelineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = WorkTimelineNavigation()
        state.view.selectedID = "selected"
        state.view.query = "query"
        state.beginArrivals()
        WorkTimelinePreferences.save(state, taskID: "task-a", defaults: defaults)
        XCTAssertEqual(WorkTimelinePreferences.load(taskID: "task-a", defaults: defaults), state)
        XCTAssertEqual(WorkTimelinePreferences.load(taskID: "task-b", defaults: defaults), WorkTimelineNavigation())
        let data = try XCTUnwrap(defaults.data(forKey: WorkTimelinePreferences.key("task-a")))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("records"))
    }

    func testReceiptAnonymousChecksRetainIdentityAcrossEnrichmentWithoutInventingSession() throws {
        let receipt = try decodeReceipt(checks: [["kind": "test", "name": "Suite", "result": "failed", "at": 10],
                                                   ["kind": "test", "name": "Suite", "result": "failed", "at": 10]])
        let projected = WorkTimelineProjection(receipt: receipt, sessions: [:])
        XCTAssertEqual(projected.records.count, 2)
        XCTAssertEqual(Set(projected.records.map(\.id)).count, 2)
        XCTAssertTrue(projected.records.allSatisfy { $0.eventID == nil && $0.laneID == "task:task-a" })
        XCTAssertTrue(projected.notices.contains { $0.contains("no event/session IDs") })
    }

    func testLoadedSessionMustMatchReceiptMemberBeforeJoining() throws {
        let receipt = try decodeReceipt(checks: [], sessions: [[
            "root": ["client": "codex", "client_session_id": "expected"],
            "members": [["client": "codex", "client_session_id": "expected"]],
        ]])
        let json: [String: Any] = ["schema": "test", "session": ["client": "codex", "client_session_id": "other"],
                                   "steps": [["work_id": "step", "title": "Unrelated", "started_at": 10]], "descendants": []]
        let detail = try JSONDecoder().decode(V1SessionDetail.self, from: JSONSerialization.data(withJSONObject: json))
        let projection = WorkTimelineProjection(receipt: receipt, sessions: ["codex::expected": detail])
        XCTAssertTrue(projection.records.isEmpty)
        XCTAssertTrue(projection.notices.contains { $0.contains("did not match") })
    }

    func testArrivalReviewAndReturnRestoreHeldEvidenceIncludingRemovedSelection() {
        let original = record("selected", time: 10)
        var feed = WorkTimelineFeed()
        feed.ingest(.init(records: [original]), following: false)
        feed.ingest(.init(records: [record("late-arrival", time: 5)]), following: false)
        feed.reviewArrivals()
        XCTAssertEqual(feed.arrivalIDs, ["selected", "late-arrival"])
        XCTAssertEqual(feed.removedArrivalCount, 1)
        XCTAssertEqual(feed.visible.records.map(\.id), ["late-arrival"])
        feed.restoreHistory()
        XCTAssertEqual(feed.visible.records, [original])
        XCTAssertEqual(feed.pendingIDs, ["selected", "late-arrival"])
        XCTAssertNil(feed.historySnapshot)
    }

    func testKeyboardOrderMatchesGroupedTimelineAndChronologicalList() {
        var a = record("a", time: 10); a.laneID = "root"
        var b = record("b", time: 20); b.laneID = "child"
        var c = record("c", time: 30); c.laneID = "root"
        var undated = record("unknown"); undated.laneID = "child"
        let projection = WorkTimelineProjection(records: [a, b, c, undated], lanes: [
            .init(id: "root", title: "Root", lineage: "", availability: "loaded"),
            .init(id: "child", title: "Child", lineage: "", availability: "loaded")])
        XCTAssertEqual(projection.displayedOrder(projection.records, mode: "timeline").map(\.id), ["a", "c", "b", "unknown"])
        XCTAssertEqual(projection.displayedOrder(projection.records, mode: "list").map(\.id), ["a", "b", "c", "unknown"])
    }

    func testLiveTargetUsesLatestUpdateOfAnEarlierSection() {
        var earlier = record("ongoing", time: 10); earlier.end = 50
        let recentStart = record("recent-check", time: 40)
        XCTAssertEqual(WorkTimelineProjection(records: [earlier, recentStart]).newestRecord?.id, "ongoing")
    }

    private func record(_ id: String, time: Double? = nil) -> WorkTimelineRecord {
        WorkTimelineRecord(id: id, laneID: "session", laneTitle: "Session", lineage: "Root", kind: .check,
                           title: "Check", start: time)
    }

    private func decodeReceipt(checks: [[String: Any]], sessions: [[String: Any]] = []) throws -> Receipt {
        let json: [String: Any] = [
            "schema_version": "test", "task_id": "task-a",
            "axes": ["decision_status": ["key": "unknown"], "evidence_strength": ["key": "unchecked"]],
            "dimensions": ["task": [:], "actors": [:], "actions": [:], "cost": [:], "evidence": ["checks": checks],
                           "outcome": [:], "gaps": [:], "provenance": [:]],
            "sessions": sessions,
        ]
        return try JSONDecoder().decode(Receipt.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
