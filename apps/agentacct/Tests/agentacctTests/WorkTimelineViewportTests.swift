import AppKit
import XCTest
@testable import agentacct

final class WorkTimelineViewportTests: XCTestCase {
    func testOffsetsClampAfterResizeAndRejectNonfiniteValues() {
        let size = CGSize(width: 600, height: 1_000)
        let viewport = CGSize(width: 400, height: 500)
        XCTAssertEqual(WorkTimelineScrollOffset(x: 90, y: 300).clamped(document: size, viewport: viewport), CGPoint(x: 90, y: 300))
        XCTAssertEqual(WorkTimelineScrollOffset(x: -50, y: 999).clamped(document: size, viewport: viewport), CGPoint(x: 0, y: 500))
        XCTAssertEqual(WorkTimelineScrollOffset(x: .nan, y: .infinity).clamped(document: size, viewport: viewport), .zero)
        XCTAssertEqual(WorkTimelineScrollOffset(x: 5, y: 10).clamped(document: .zero, viewport: viewport), .zero)
    }

    @MainActor func testCaptureRestoresScrollPositionRatherThanSelectedRecord() throws {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 1_400))
        scroll.documentView = document
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let viewport = WorkTimelineViewport()
        viewport.anchor = anchor
        scroll.contentView.scroll(to: CGPoint(x: 80, y: 550))
        let captured = try XCTUnwrap(viewport.capture())
        scroll.contentView.scroll(to: .zero)
        XCTAssertTrue(viewport.restore(captured))
        XCTAssertEqual(viewport.capture(), captured)
        XCTAssertFalse(viewport.restore([]))
    }

    func testNestedArrivalReviewKeepsOriginalGeometryAndDisclosureChoices() throws {
        var navigation = WorkTimelineNavigation()
        navigation.view.selectedID = "previously-selected"
        navigation.view.scrollOffsets = [.init(x: 30, y: 850), .init(x: 0, y: 170)]
        navigation.view.overviewExpanded = true
        navigation.view.comparisonExpanded = false
        let original = navigation.view
        navigation.beginArrivals()
        navigation.view.scrollOffsets = [.init(x: 0, y: 0)]
        navigation.view.comparisonExpanded = true
        navigation.beginArrivals()
        navigation.returnToHistory()
        XCTAssertEqual(navigation.view, original)
        let saved = try JSONEncoder().encode(navigation)
        XCTAssertEqual(try JSONDecoder().decode(WorkTimelineNavigation.self, from: saved), navigation)
    }

    func testFileInvestigationRestoresFiltersAcrossFilesAndArrivalReview() {
        var navigation = WorkTimelineNavigation()
        navigation.view.query = "failed build"
        navigation.view.failuresOnly = true
        navigation.view.interval = .init(lower: 100, upper: 200)
        navigation.view.selectedID = "selected"
        navigation.view.compareIDs = ["a", "b"]
        let original = navigation.view
        navigation.showFile("first.swift")
        navigation.showFile("second.swift")
        XCTAssertNil(navigation.view.interval)
        XCTAssertFalse(navigation.view.failuresOnly)
        XCTAssertEqual(navigation.view.query, "")
        navigation.beginArrivals()
        navigation.returnToHistory()
        XCTAssertEqual(navigation.view.file, "second.swift")
        navigation.leaveFile()
        XCTAssertEqual(navigation.view, original)
        XCTAssertFalse(navigation.following)
    }

    func testOlderBookmarkDecodesWithoutGeometry() throws {
        let old = Data(#"{"selectedID":"a","query":"","failuresOnly":false,"mode":"timeline","compareIDs":[]}"#.utf8)
        let bookmark = try JSONDecoder().decode(WorkTimelineBookmark.self, from: old)
        XCTAssertNil(bookmark.scrollOffsets)
        XCTAssertNil(bookmark.overviewExpanded)
    }
}
