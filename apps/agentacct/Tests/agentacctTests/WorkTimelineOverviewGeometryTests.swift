import SwiftUI
import XCTest
@testable import agentacct

final class WorkTimelineOverviewGeometryTests: XCTestCase {
    func testEveryDrawnLaneCenterHitsItsOwnLaneAtDefaultAndAccessibilitySizes() {
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            let geometry = WorkTimelineOverviewGeometry(dynamicTypeSize: size)
            for count in [1, 3, 6] {
                for index in 0..<count {
                    let center = geometry.laneCenter(at: index)
                    XCTAssertEqual(geometry.laneIndex(at: center, laneCount: count), index)
                    XCTAssertEqual(geometry.laneIndex(at: center - geometry.hitTolerance * 0.99, laneCount: count), index)
                    XCTAssertEqual(geometry.laneIndex(at: center + geometry.hitTolerance * 0.99, laneCount: count), index)
                    XCTAssertGreaterThan(center - geometry.selectionRadius, 0)
                    XCTAssertLessThan(center + geometry.selectionRadius, geometry.height(laneCount: count))
                }
            }
        }
    }

    func testLaneGapsAndOutsideCanvasCannotSelectAnAdjacentLane() {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let geometry = WorkTimelineOverviewGeometry(dynamicTypeSize: size)
            XCTAssertNil(geometry.laneIndex(at: 0, laneCount: 3))
            XCTAssertNil(geometry.laneIndex(at: -1, laneCount: 3))
            XCTAssertNil(geometry.laneIndex(at: geometry.height(laneCount: 3), laneCount: 3))
            XCTAssertNil(geometry.laneIndex(at: .infinity, laneCount: 3))
            XCTAssertNil(geometry.laneIndex(at: .nan, laneCount: 3))
            XCTAssertNil(geometry.laneIndex(at: geometry.laneCenter(at: 0), laneCount: 0))
            for index in 0..<2 {
                let boundary = geometry.verticalInset + CGFloat(index + 1) * geometry.laneHeight
                XCTAssertNil(geometry.laneIndex(at: boundary, laneCount: 3))
            }
        }
    }

    func testExplicitScaleAndLargerSystemScaleKeepLabelsAndDrawingInProportion() {
        let base = WorkTimelineOverviewGeometry(dynamicTypeSize: .large)
        let accessible = WorkTimelineOverviewGeometry(dynamicTypeSize: .accessibility3)
        let largerSystem = WorkTimelineOverviewGeometry(dynamicTypeSize: .accessibility3, systemScale: 2.5)
        XCTAssertEqual(base.laneHeight, 15)
        XCTAssertEqual(base.labelWidth, 150)
        XCTAssertGreaterThan(accessible.laneHeight, base.laneHeight)
        XCTAssertGreaterThan(accessible.labelWidth, base.labelWidth)
        XCTAssertGreaterThan(largerSystem.laneHeight, accessible.laneHeight)
        for geometry in [accessible, largerSystem] {
            let scale = geometry.laneHeight / base.laneHeight
            XCTAssertEqual(geometry.labelWidth / base.labelWidth, scale, accuracy: 0.0001)
            XCTAssertEqual(geometry.hitTolerance / base.hitTolerance, scale, accuracy: 0.0001)
            XCTAssertEqual(geometry.laneCenter(at: 2) / base.laneCenter(at: 2), scale, accuracy: 0.0001)
            XCTAssertEqual(geometry.height(laneCount: 3) / base.height(laneCount: 3), scale, accuracy: 0.0001)
        }
    }

    func testScaledVerticalAndHorizontalHitTestingStillSelectsTheExactNamedRecord() {
        let geometry = WorkTimelineOverviewGeometry(dynamicTypeSize: .accessibility3)
        let full = WorkTimelineInterval(lower: 0, upper: 1_000)
        let records = ["root", "child-a", "child-b"].map { lane in
            WorkTimelineRecord(id: "event-\(lane)", laneID: lane, laneTitle: lane, lineage: "Recorded relationship", kind: .check, title: "Check", start: 500)
        }
        let laneIndex = geometry.laneIndex(at: geometry.laneCenter(at: 2), laneCount: records.count)
        XCTAssertEqual(laneIndex, 2)
        let selected = laneIndex.flatMap { index in
            WorkTimelineRangeNavigation.hitRecord(records, laneID: records[index].laneID, x: 500, width: 1_000, within: full, tolerance: geometry.hitTolerance)
        }
        XCTAssertEqual(selected?.id, "event-child-b")
        XCTAssertNil(WorkTimelineRangeNavigation.hitRecord(records, laneID: "child-b", x: 700, width: 1_000, within: full, tolerance: geometry.hitTolerance))
    }
}
