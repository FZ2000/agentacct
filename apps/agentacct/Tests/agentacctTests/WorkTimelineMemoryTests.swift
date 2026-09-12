import XCTest
@testable import agentacct

final class WorkTimelineMemoryTests: XCTestCase {
    func testCacheEvictsLeastRecentlyViewedTaskAndRetainsHeldSnapshot() {
        var cache = WorkTimelineMemoryCache(taskLimit: 2)
        var first = entry("original")
        first.feed.ingest(.init(records: [record("arrival")]), following: false)
        first.feed.reviewArrivals()
        cache.save(first, for: "a")
        cache.save(entry("second"), for: "b")
        _ = cache.load("a")
        cache.save(entry("third"), for: "c")
        XCTAssertNil(cache.load("b"))
        var restored = cache.load("a")!
        restored.feed.restoreHistory()
        XCTAssertEqual(restored.feed.visible.records.map(\.id), ["original"])
        XCTAssertEqual(restored.feed.pendingIDs, ["original", "arrival"])
    }

    func testRecordBudgetEvictsOlderEntriesAndDoesNotRetainOversizedTask() {
        var cache = WorkTimelineMemoryCache(taskLimit: 8, recordLimit: 4)
        cache.save(entry("one"), for: "a")
        cache.save(entry("two"), for: "b")
        cache.save(entry("three"), for: "c")
        XCTAssertNil(cache.load("a"))
        XCTAssertNotNil(cache.load("b"))
        var oversized = entry("big")
        oversized.feed.ingest(.init(records: (0..<5).map { record("r\($0)") }), following: true)
        cache.save(oversized, for: "large")
        XCTAssertNil(cache.load("large"))
        XCTAssertNotNil(cache.load("b"))
        XCTAssertNotNil(cache.load("c"))
    }

    func testMissingSnapshotRestoresOriginalBookmarkWithoutClaimingArrivalHistory() {
        var navigation = WorkTimelineNavigation()
        navigation.view.query = "original query"
        navigation.view.selectedID = "selected"
        navigation.view.compareIDs = ["a", "b"]
        let original = navigation.view
        navigation.beginArrivals()
        navigation.view.query = "arrival query"
        XCTAssertTrue(navigation.restorePositionWithoutSnapshot())
        XCTAssertEqual(navigation.view, original)
        XCTAssertNil(navigation.history)
        XCTAssertFalse(navigation.following)
        var fresh = WorkTimelineNavigation()
        XCTAssertFalse(fresh.restorePositionWithoutSnapshot())
        XCTAssertTrue(fresh.following)
    }

    private func record(_ id: String) -> WorkTimelineRecord {
        WorkTimelineRecord(id: id, laneID: "s", laneTitle: "S", lineage: "root", kind: .check, title: id, start: 10)
    }
    private func entry(_ id: String) -> WorkTimelineMemoryCache.Entry {
        var feed = WorkTimelineFeed()
        feed.ingest(.init(records: [record(id)]), following: false)
        return .init(feed: feed, sessions: [:])
    }
}
