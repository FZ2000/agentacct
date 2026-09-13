import CoreGraphics
import XCTest
@testable import agentacct

final class WorkTimeCanvasLayoutTests: XCTestCase {
    private let full = WorkTimelineInterval(lower: 100, upper: 200)

    func testTimeSetsAnchorsAndFourCoincidentRecordsUseBothSides() {
        let records = ["d", "c", "b", "a"].map { record($0, start: 125) }
        let layout = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: 420)

        XCTAssertEqual(layout.items.count, 4)
        XCTAssertEqual(layout.bandCountPerSide, 2)
        XCTAssertEqual(layout.items.filter(\.isAbove).count, 2)
        XCTAssertEqual(layout.items.filter { !$0.isAbove }.count, 2)
        XCTAssertTrue(layout.items.allSatisfy { $0.anchorX == 250 && !$0.isCluster })
        assertReadable(layout, width: 1000, height: 420)
        for item in layout.items where !item.isAbove {
            XCTAssertGreaterThanOrEqual(item.frame.minY, layout.axisY + 44)
        }
    }

    func testLayoutRetainsOffscreenRecordsAndCullingIsPresentationOnly() {
        let records = [
            record("far", start: 10, end: 20),
            record("before", start: 80, end: 99),
            record("crossing", start: 50, end: 250),
            record("left", start: 100),
            record("right", start: 200),
            record("after", start: 201),
            record("farAfter", start: 500),
            record("undated", start: nil),
            record("invalid", start: .nan),
        ]
        let layout = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: 420)

        // Every dated record keeps a stable placement, including records
        // outside the window: that is what lets panning translate cards
        // instead of regrouping them at the viewport edges.
        XCTAssertEqual(Set(layout.items.flatMap(\.recordIDs)),
            ["after", "before", "crossing", "far", "farAfter", "left", "right"])
        XCTAssertEqual(layout.visibleRecordCount, 3)
        XCTAssertEqual(layout.undatedRecordIDs, ["invalid", "undated"])
        let crossing = layout.items.first { $0.recordIDs.contains("crossing") }
        XCTAssertEqual(crossing?.timeBounds, .init(lower: 50, upper: 250))
        // Anchors are no longer clipped to the viewport: 50 lies half a window
        // before the window's lower bound, so its position is offscreen.
        XCTAssertEqual(crossing?.anchorX, -500)
        let visible = layout.visibleCards(in: 1000)
        XCTAssertEqual(Set(visible.flatMap(\.recordIDs)), ["after", "before", "left", "right"],
            "Cards render only near the viewport: the accessibility tree never holds an invisible card")
        XCTAssertEqual(layout.crossingSpans(in: 1000).map(\.recordIDs), [["crossing"]],
            "A span crossing the window keeps its line on screen without pinning a card")
        assertReadable(layout, width: 1000, height: 420)
    }

    func testPanningTranslatesEveryItemWithoutRegrouping() {
        let records = (0..<300).map { record("event-\($0)", start: 100 + Double(($0 * 7919) % 10000) / 100) }
        let base = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: 420)
        let shifted = WorkTimeCanvasLayout(records: records, window: .init(lower: 130, upper: 230), width: 1000, height: 420)

        // Same items, same members, same sides: a pan only translates.
        XCTAssertEqual(base.items.map(\.id), shifted.items.map(\.id))
        XCTAssertEqual(base.items.map(\.recordIDs), shifted.items.map(\.recordIDs))
        let dx = 30 / full.span * 1000
        for (baseItem, shiftedItem) in zip(base.items, shifted.items) {
            XCTAssertEqual(shiftedItem.anchorX, baseItem.anchorX - dx, accuracy: 0.000_001)
            XCTAssertEqual(shiftedItem.frame.minX, baseItem.frame.minX - dx, accuracy: 0.000_001)
            XCTAssertEqual(shiftedItem.frame.minY, baseItem.frame.minY)
            XCTAssertEqual(shiftedItem.isAbove, baseItem.isAbove)
            XCTAssertEqual(shiftedItem.timeBounds, baseItem.timeBounds)
        }
        assertReadable(shifted, width: 1000, height: 420)
    }

    func testSixThousandCoincidentRecordsRemainBoundedAndFullyInspectable() {
        let records = (0..<6000).map { record("event-\($0)", start: 125) }
        let layout = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: 420)

        XCTAssertEqual(layout.items.count, 4)
        XCTAssertTrue(layout.items.contains(where: \.isCluster))
        XCTAssertEqual(layout.items.reduce(0) { $0 + $1.count }, records.count)
        XCTAssertEqual(Set(layout.items.flatMap(\.recordIDs)), Set(records.map(\.id)))
        XCTAssertTrue(layout.items.allSatisfy { $0.timeBounds == .init(lower: 125, upper: 125) })
        let reordered = WorkTimeCanvasLayout(records: records.reversed(), window: full, width: 1000, height: 420)
        XCTAssertEqual(layout.items, reordered.items)
        assertReadable(layout, width: 1000, height: 420)
    }

    func testSparseRecordsAndFourNarrowCoincidentRecordsDoNotOvercollapse() {
        let sparse = (0..<8).map { record("event-\($0)", start: 105 + Double($0) * 12) }
        let broad = WorkTimeCanvasLayout(records: sparse, window: full, width: 1000, height: 420)
        XCTAssertEqual(broad.items.count, sparse.count)
        XCTAssertFalse(broad.items.contains(where: \.isCluster))
        let simultaneous = (0..<4).map { record("same-\($0)", start: 150) }
        let narrow = WorkTimeCanvasLayout(records: simultaneous, window: full, width: 180, height: 420)
        XCTAssertEqual(narrow.items.count, simultaneous.count)
        XCTAssertFalse(narrow.items.contains(where: \.isCluster))
        assertReadable(narrow, width: 180, height: 420)
    }

    func testDenseUnevenHistoryPacksWithoutOverlapOrLostMembers() {
        let records = (0..<6000).map { index in
            // Distinct deterministic times include multiple bursts at bin edges.
            record("event-\(index)", start: 100 + Double((index * 7919) % 10000) / 100)
        }
        for width in [180.0, 360, 1000, 1800] {
            let layout = WorkTimeCanvasLayout(records: records, window: full, width: width, height: 420)
            let memberIDs = layout.items.flatMap(\.recordIDs)
            XCTAssertEqual(memberIDs.count, records.count, "width \(width)")
            XCTAssertEqual(Set(memberIDs), Set(records.map(\.id)), "width \(width)")
            XCTAssertEqual(Set(layout.items.map(\.id)).count, layout.items.count)
            assertReadable(layout, width: width, height: 420)
        }
    }

    func testZoomRevealsDenseMembersWithoutInventingTheirTime() {
        let records = (0..<12).map { record("event-\($0)", start: 125 + Double($0)) }
        let broad = WorkTimeCanvasLayout(records: records, window: full, width: 1600, height: 420)
        let close = WorkTimeCanvasLayout(records: records, window: .init(lower: 124, upper: 137), width: 1600, height: 420)

        XCTAssertTrue(broad.items.contains(where: \.isCluster))
        XCTAssertGreaterThan(close.items.count, broad.items.count)
        XCTAssertEqual(Set(close.items.flatMap(\.recordIDs)), Set(records.map(\.id)))
        assertReadable(close, width: 1600, height: 420)
    }

    func testLargeTextUsesFewerBandsAndPreservesReadableLabelStrip() {
        let records = (0..<30).map { record("event-\($0)", start: 100 + Double($0) * 3) }
        for scale in [1.85, 2.3] {
            let height = max(420, WorkTimeCanvasLayout.minimumHeight(textScale: scale))
            let layout = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: height, textScale: scale)
            XCTAssertEqual(layout.bandCountPerSide, 1)
            XCTAssertEqual(layout.cardHeight, 80 * scale)
            XCTAssertEqual(Set(layout.items.flatMap(\.recordIDs)), Set(records.map(\.id)))
            for item in layout.items where !item.isAbove {
                XCTAssertGreaterThanOrEqual(item.frame.minY, layout.axisY + 44 * scale)
            }
            assertReadable(layout, width: 1000, height: height)
        }
    }

    func testInvalidGeometryHasNoNonfiniteFramesOrHiddenRecordCount() {
        let records = [record("valid", start: 125)]
        for dimensions in [(0.0, 420.0), (1000.0, 0.0), (.infinity, 420.0), (1000.0, .nan), (-1.0, -1.0)] {
            let layout = WorkTimeCanvasLayout(records: records, window: full, width: dimensions.0, height: dimensions.1)
            XCTAssertTrue(layout.items.isEmpty)
            XCTAssertEqual(layout.visibleRecordCount, 1)
            XCTAssertTrue(layout.axisY.isFinite)
        }
        let invalidScale = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: 420, textScale: .nan)
        XCTAssertEqual(invalidScale.cardHeight, 80)
        assertReadable(invalidScale, width: 1000, height: 420)
    }

    func testPanPreservesSpanAndSaturatesAtDomainEdges() {
        let window = WorkTimelineInterval(lower: 120, upper: 140)
        XCTAssertEqual(WorkTimeCanvasLayout.pannedWindow(window, by: 10, within: full), .init(lower: 130, upper: 150))
        XCTAssertEqual(WorkTimeCanvasLayout.pannedWindow(window, by: .greatestFiniteMagnitude, within: full), .init(lower: 180, upper: 200))
        XCTAssertEqual(WorkTimeCanvasLayout.pannedWindow(window, by: -.greatestFiniteMagnitude, within: full), .init(lower: 100, upper: 120))
        XCTAssertEqual(WorkTimeCanvasLayout.pannedWindow(window, by: .nan, within: full), window)
    }

    func testEdgeRevealIsACappedFractionOfTheVisibleSpan() {
        let window = WorkTimelineInterval(lower: 100, upper: 200)
        // 15% of the span, independent of width or card size, so the canvas
        // and the view clamp every produced window the same way.
        XCTAssertEqual(WorkTimeCanvasLayout.edgeRevealTime(window: window),
                       WorkTimeCanvasLayout.maximumEdgeRevealFraction * 100, accuracy: 0.000_001)
        // Degenerate spans stay finite and positive.
        XCTAssertEqual(WorkTimeCanvasLayout.edgeRevealTime(window: .init(lower: 0, upper: .nan)),
                       WorkTimeCanvasLayout.maximumEdgeRevealFraction, accuracy: 0.000_001)
    }

    func testExpandedDomainAddsTheEdgeRevealWithinBounds() {
        let full = WorkTimelineInterval(lower: 100, upper: 200)
        XCTAssertEqual(WorkTimeCanvasLayout.expandedDomain(full, by: 10), .init(lower: 90, upper: 210))
        XCTAssertEqual(WorkTimeCanvasLayout.expandedDomain(full, by: 0), full)
        XCTAssertEqual(WorkTimeCanvasLayout.expandedDomain(full, by: .nan), full)
        XCTAssertEqual(WorkTimeCanvasLayout.expandedDomain(full, by: -.infinity), full)
    }

    func testExpandedDomainFallsBackWhenEndpointsOrSpanOverflow() {
        let belowZero = WorkTimelineInterval(lower: -.greatestFiniteMagnitude, upper: -.greatestFiniteMagnitude / 2)
        XCTAssertEqual(WorkTimeCanvasLayout.expandedDomain(belowZero, by: 1), belowZero)
        // Finite endpoints whose span overflows also fall back instead of
        // defeating the zoom-out bound.
        let wide = WorkTimelineInterval(lower: -8e307, upper: 8e307)
        XCTAssertEqual(WorkTimeCanvasLayout.expandedDomain(wide, by: 2.4e307), wide)
    }

    func testPanningReachesTheEdgeRevealSoTheFirstCardFitsInFull() throws {
        let full = WorkTimelineInterval(lower: 100, upper: 200)
        let window = WorkTimelineInterval(lower: 100, upper: 130)
        let reveal = WorkTimeCanvasLayout.edgeRevealTime(window: window)
        let domain = WorkTimeCanvasLayout.expandedDomain(full, by: reveal)
        let earliest = WorkTimeCanvasLayout.pannedWindow(window, by: -1_000, within: domain)

        XCTAssertEqual(earliest.lower, full.lower - reveal, accuracy: 0.000_001)
        // A record at the recorded domain's lower bound lands at least half a
        // 200pt card inside a 1000pt viewport at the extreme position.
        let layout = WorkTimeCanvasLayout(records: [record("first", start: 100)],
            window: earliest, width: 1000, height: 420)
        let item = try XCTUnwrap(layout.visibleCards(in: 1000).first)
        XCTAssertGreaterThanOrEqual(item.frame.minX, 0, "the first card is fully inside at the extreme")
        XCTAssertEqual(item.frame.minX, 50, accuracy: 0.000_001)
    }

    func testZoomKeepsPointerTimeAnchoredUntilDomainEdgeRequiresClamping() {
        let window = WorkTimelineInterval(lower: 120, upper: 180)
        let zoomed = WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorFraction: 0.25, within: full)
        XCTAssertEqual(zoomed.upper - zoomed.lower, 30, accuracy: 0.000001)
        XCTAssertEqual(zoomed.lower + (zoomed.upper - zoomed.lower) * 0.25, 135, accuracy: 0.000001)
        XCTAssertEqual(WorkTimeCanvasLayout.zoomedWindow(window, factor: 0.001, anchorFraction: 0, within: full), full)
        let smallest = WorkTimeCanvasLayout.zoomedWindow(window, factor: .greatestFiniteMagnitude, anchorFraction: 0.25, within: full)
        XCTAssertEqual(smallest.upper - smallest.lower, WorkTimeCanvasLayout.minimumVisibleSpan, accuracy: 0.000001)
        XCTAssertEqual(smallest.lower + (smallest.upper - smallest.lower) * 0.25, 135, accuracy: 0.000001)
        XCTAssertEqual(WorkTimeCanvasLayout.zoomedWindow(window, factor: .nan, anchorFraction: 0, within: full), window)
    }

    func testWindowSpanNeverShrinksBelowTheReadableMinimum() {
        let window = WorkTimelineInterval(lower: 120, upper: 140)
        let zoomed = WorkTimeCanvasLayout.zoomedWindow(window, factor: 1_000_000, anchorFraction: 0.5, within: full)
        XCTAssertEqual(zoomed.upper - zoomed.lower, WorkTimeCanvasLayout.minimumVisibleSpan, accuracy: 0.000001)
        // Unless the whole recorded domain is smaller than the minimum.
        let tiny = WorkTimelineInterval(lower: 42, upper: 43)
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(tiny, to: tiny), tiny)
    }

    func testZoomByAbsoluteAnchorTimeMatchesFractionAndClampsOutsideAnchors() {
        let window = WorkTimelineInterval(lower: 120, upper: 180)
        XCTAssertEqual(WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorTime: 135, within: full),
                       WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorFraction: 0.25, within: full))
        // An anchor outside the window (the overview's domain-wide pointer)
        // clamps to the nearest window edge instead of skipping clamping.
        XCTAssertEqual(WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorTime: 500, within: full),
                       WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorFraction: 1, within: full))
        XCTAssertEqual(WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorTime: .nan, within: full),
                       WorkTimeCanvasLayout.zoomedWindow(window, factor: 2, anchorFraction: 0.5, within: full))
    }

    func testClampNormalizesReversedDegenerateAndNonfiniteWindows() {
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(.init(lower: 160, upper: 140), to: full), .init(lower: 140, upper: 160))
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(.init(lower: 200, upper: 200), to: full), .init(lower: 195, upper: 200),
            "A degenerate point window expands to the readable minimum span")
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(.init(lower: .nan, upper: 150), to: full), full)
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(full, to: .init(lower: 42, upper: 42)), .init(lower: 42, upper: 43))
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(full, to: .init(lower: -.greatestFiniteMagnitude, upper: .greatestFiniteMagnitude)), .init(lower: 0, upper: 1))
        XCTAssertEqual(WorkTimeCanvasLayout.clampedWindow(full, to: full, minimumSpan: .infinity), full)
    }

    func testLatestWindowKeepsNewestRecordVisibleWhenSevenDayDomainHasPadding() {
        let latest = 100.0 + 7 * 24 * 60 * 60
        let padding = 7.0 * 24 * 60 * 60 * 0.03
        let domain = WorkTimelineInterval(lower: 100 - padding, upper: latest + padding)
        let window = WorkTimeCanvasLayout.latestWindow(within: domain, latest: latest)

        XCTAssertLessThan(window.lower, latest)
        XCTAssertGreaterThan(window.upper, latest)
        XCTAssertEqual(window.upper, latest + 60, accuracy: 0.000001)
        XCTAssertEqual(window.upper - window.lower, 1800, accuracy: 0.000001)
        let invalidLatest: [Double?] = [nil, .nan, .infinity, -1, domain.upper + 1]
        for invalid in invalidLatest {
            XCTAssertEqual(WorkTimeCanvasLayout.latestWindow(within: domain, latest: invalid).upper, domain.upper)
        }
    }

    func testCrossingClusterSpansAreRetainedForDrawing() {
        // Five records far before the window merge into a cluster whose
        // recorded extent crosses it; its members still need drawn spans even
        // though its card is offscreen.
        var records = (0..<5).map { record("old-\($0)", start: 50, end: 250) }
        records.append(record("inside", start: 190))
        let layout = WorkTimeCanvasLayout(records: records, window: full, width: 1000, height: 420)
        let crossing = layout.crossingSpans(in: 1000)
        XCTAssertTrue(crossing.contains {
            $0.isCluster && $0.timeBounds.upper >= full.lower && $0.timeBounds.lower <= full.upper
        }, "a crossing cluster stays available for span drawing")
        let crossingIDs = crossing.flatMap(\.recordIDs)
        XCTAssertEqual(Set(crossingIDs).count, crossingIDs.count, "no member is drawn twice")
    }

    private func assertReadable(
        _ layout: WorkTimeCanvasLayout, width: Double, height: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (index, item) in layout.items.enumerated() {
            XCTAssertTrue(item.frame.origin.x.isFinite && item.frame.origin.y.isFinite, file: file, line: line)
            XCTAssertGreaterThan(item.frame.width, 0, file: file, line: line)
            XCTAssertGreaterThan(item.frame.height, 0, file: file, line: line)
            // Horizontal positions are time-true: cards may sit partly or
            // fully outside the viewport. Vertical placement stays inside.
            XCTAssertGreaterThanOrEqual(item.frame.minY, -0.000001, file: file, line: line)
            XCTAssertLessThanOrEqual(item.frame.maxY, height + 0.000001, file: file, line: line)
            XCTAssertTrue(item.anchorX.isFinite, file: file, line: line)
            for other in layout.items.dropFirst(index + 1) {
                XCTAssertFalse(item.frame.intersects(other.frame), "\(item.id) overlaps \(other.id)", file: file, line: line)
            }
        }
        // Every record whose time intersects the window stays represented:
        // either as a visible card or as a drawn span crossing an edge.
        // Culling never feeds back into placement.
        let visible = layout.visibleCards(in: width)
        let crossing = layout.crossingSpans(in: width)
        for item in layout.items
        where item.timeBounds.upper >= layout.window.lower && item.timeBounds.lower <= layout.window.upper {
            XCTAssertTrue(visible.contains(item) || crossing.contains(item),
                "\(item.id) intersects the window but is neither rendered nor drawn", file: file, line: line)
        }
    }

    private func record(_ id: String, start: Double?, end: Double? = nil) -> WorkTimelineRecord {
        .init(id: id, laneID: "session", laneTitle: "Session", lineage: "Recorded session", kind: .step, title: id, start: start, end: end)
    }
}
