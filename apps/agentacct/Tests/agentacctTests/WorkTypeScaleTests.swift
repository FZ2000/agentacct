import SwiftUI
import XCTest
@testable import agentacct

final class WorkTypeScaleTests: XCTestCase {
    func testLargeReadingSizeGrowsEvenWhenHostReturnsBaseMetric() {
        let sizes: [DynamicTypeSize] = [.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        for base: CGFloat in [12, 14, 26, 180, 220] {
            let resolved = sizes.map { WorkTypeScale.resolved(base: base, systemScaled: base, dynamicTypeSize: $0) }
            XCTAssertEqual(resolved.first, base)
            XCTAssertGreaterThan(resolved.last!, base * 2)
            for (previous, next) in zip(resolved, resolved.dropFirst()) { XCTAssertGreaterThan(next, previous) }
        }
    }

    func testLargerSystemMetricWinsWithoutDoubleScalingAndDefaultIsPreserved() {
        XCTAssertEqual(WorkTypeScale.resolved(base: 14, systemScaled: 40, dynamicTypeSize: .accessibility3), 40)
        XCTAssertEqual(WorkTypeScale.resolved(base: 14, systemScaled: 14, dynamicTypeSize: .large), 14)
        XCTAssertEqual(WorkTypeScale.resolved(base: 14, systemScaled: 14, dynamicTypeSize: .medium), 14)
    }
}
