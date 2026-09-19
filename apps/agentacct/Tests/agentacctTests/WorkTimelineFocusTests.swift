import XCTest
@testable import agentacct

final class WorkTimelineFocusTests: XCTestCase {
    func testReturnRequestKeepsOriginalRecordAcrossRemountAndIsConsumedOnce() {
        var focus = WorkTimelineFocusRestoration()
        focus.remember(taskID: "a", recordID: "check-failed")
        focus.prepare(taskID: "a")
        focus.remember(taskID: "a", recordID: nil)
        XCTAssertEqual(focus.consume(taskID: "a", visibleRecordIDs: ["check-failed", "check-passed"]), .record("check-failed"))
        XCTAssertNil(focus.consume(taskID: "a", visibleRecordIDs: ["check-failed"]))
    }

    func testMissingOrFilteredRecordReturnsToHeadingWithoutSelectingDifferentEvidence() {
        var focus = WorkTimelineFocusRestoration()
        focus.remember(taskID: "a", recordID: "removed")
        focus.prepare(taskID: "a")
        XCTAssertEqual(focus.consume(taskID: "a", visibleRecordIDs: ["another"]), .heading)
    }

    func testNewInvestigationActionCancelsPendingReturnFocus() {
        var focus = WorkTimelineFocusRestoration()
        focus.remember(taskID: "a", recordID: "earlier")
        focus.prepare(taskID: "a")
        focus.cancel()
        XCTAssertNil(focus.consume(taskID: "a", visibleRecordIDs: ["earlier"]))
    }

    func testTaskChangeDiscardsPendingFocusAndCannotBorrowAnotherTaskRecord() {
        var focus = WorkTimelineFocusRestoration()
        focus.remember(taskID: "a", recordID: "same-looking-id")
        focus.prepare(taskID: "a")
        XCTAssertNil(focus.consume(taskID: "b", visibleRecordIDs: ["same-looking-id"]))
        focus.prepare(taskID: "b")
        XCTAssertEqual(focus.consume(taskID: "b", visibleRecordIDs: ["same-looking-id"]), .heading)
    }
}
