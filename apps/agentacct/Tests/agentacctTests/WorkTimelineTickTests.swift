import XCTest
@testable import agentacct

/// Axis ticks are anchored to absolute time so panning translates marks across
/// the screen. These tests pin the step ladder, the anchoring, local-midnight
/// alignment and viewport-independent label text.
final class WorkTimelineTickTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    func testStepKeepsReadableSpacingAcrossScales() {
        // A 30-minute window at 1000pt uses 5-minute marks 166pt apart.
        XCTAssertEqual(WorkTimelineTimeAxis.tickStep(span: 1800, width: 1000, minimumSpacing: 100), 300)
        // A 7-day window uses daily marks; a one-minute window uses 10 seconds.
        XCTAssertEqual(WorkTimelineTimeAxis.tickStep(span: 7 * 86_400, width: 1000, minimumSpacing: 100), 86_400)
        XCTAssertEqual(WorkTimelineTimeAxis.tickStep(span: 60, width: 1000, minimumSpacing: 100), 10)
        // Degenerate input still yields a finite positive step, and spans
        // beyond the ladder keep growing instead of collapsing to zero.
        let fallback = WorkTimelineTimeAxis.tickStep(span: .nan, width: 0, minimumSpacing: 0)
        XCTAssertTrue(fallback.isFinite && fallback > 0)
        XCTAssertTrue(WorkTimelineTimeAxis.tickStep(span: 1e12, width: 1000, minimumSpacing: 100).isFinite)
    }

    func testTicksAreAnchoredToAbsoluteTimeAndTranslateWithPanning() {
        let window = WorkTimelineInterval(lower: 1_789_234_567, upper: 1_789_236_367) // 30 minutes
        let base = WorkTimelineTimeAxis.ticks(in: window, width: 1000, minimumSpacing: 100)
        XCTAssertEqual(base.step, 300)
        XCTAssertEqual(base.times.first!, (window.lower / 300).rounded(.up) * 300, accuracy: 0.0001)
        for (earlier, later) in zip(base.times, base.times.dropFirst()) {
            XCTAssertEqual(later - earlier, 300, accuracy: 0.0001)
            XCTAssertTrue(window.lower...window.upper ~= earlier)
        }
        // Panning by exactly one step yields the same marks shifted by one
        // step: marks move with time, they are not recomputed from fractions.
        let panned = WorkTimelineTimeAxis.ticks(
            in: WorkTimelineInterval(lower: window.lower + 300, upper: window.upper + 300),
            width: 1000, minimumSpacing: 100)
        XCTAssertEqual(panned.step, base.step)
        XCTAssertEqual(panned.times.map { $0 - 300 }, base.times)
    }

    func testDayStepsAlignToLocalMidnight() {
        let calendar = calendar("America/Chicago")
        let start = Date(timeIntervalSince1970: 1_789_234_567)
        let window = WorkTimelineInterval(lower: start.timeIntervalSince1970,
                                          upper: start.timeIntervalSince1970 + 7 * 86_400)
        let ticks = WorkTimelineTimeAxis.ticks(in: window, width: 1600, minimumSpacing: 100, calendar: calendar)
        XCTAssertEqual(ticks.step, 86_400)
        XCTAssertFalse(ticks.times.isEmpty)
        for tick in ticks.times {
            XCTAssertEqual(Date(timeIntervalSince1970: tick),
                           calendar.startOfDay(for: Date(timeIntervalSince1970: tick)))
            XCTAssertTrue(window.lower...window.upper ~= tick)
        }
    }

    func testMultiDayLatticesStayAnchoredAcrossPanning() {
        let calendar = calendar("America/Chicago")
        let start = Date(timeIntervalSince1970: 1_789_234_567) // September: no DST change inside the window
        let window = WorkTimelineInterval(lower: start.timeIntervalSince1970,
                                          upper: start.timeIntervalSince1970 + 14 * 86_400)
        let base = WorkTimelineTimeAxis.ticks(in: window, width: 1000, minimumSpacing: 100, calendar: calendar)
        XCTAssertEqual(base.step, 259_200)
        // Panning by one lattice period yields the same absolute marks shifted:
        // the lattice phase comes from the epoch, not from the window.
        let panned = WorkTimelineTimeAxis.ticks(
            in: WorkTimelineInterval(lower: window.lower + 3 * 86_400, upper: window.upper + 3 * 86_400),
            width: 1000, minimumSpacing: 100, calendar: calendar)
        XCTAssertEqual(panned.step, base.step)
        XCTAssertEqual(panned.times.map { $0 - 3 * 86_400 }, base.times)
    }

    func testTickLabelsDependOnTimeAndStepNotWindowPosition() {
        let calendar = calendar("America/New_York")
        let day = Date(timeIntervalSince1970: 1_789_234_567)
        let midnight = calendar.startOfDay(for: day)
        let afternoon = calendar.date(bySettingHour: 15, minute: 30, second: 15, of: day)!
        let sameDay = WorkTimelineInterval(lower: midnight.timeIntervalSince1970,
                                           upper: midnight.timeIntervalSince1970 + 3_600)
        func reference(_ template: String, _ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        // Minute steps inside one day label a plain time.
        XCTAssertEqual(WorkTimelineTimeAxis.tickLabel(afternoon.timeIntervalSince1970, step: 300,
                                                      range: sameDay, calendar: calendar),
                       reference("jm", afternoon))
        // Sub-minute steps keep seconds.
        XCTAssertEqual(WorkTimelineTimeAxis.tickLabel(afternoon.timeIntervalSince1970, step: 10,
                                                      range: sameDay, calendar: calendar),
                       reference("jms", afternoon))
        // A local-midnight mark carries the date as a day separator.
        XCTAssertEqual(WorkTimelineTimeAxis.tickLabel(midnight.timeIntervalSince1970, step: 3_600,
                                                      range: sameDay, calendar: calendar),
                       reference("MMMdjm", midnight))
        // Once the window crosses a day boundary, every sub-day mark is dated.
        let crossDay = WorkTimelineInterval(lower: sameDay.lower, upper: sameDay.lower + 2 * 86_400)
        XCTAssertEqual(WorkTimelineTimeAxis.tickLabel(afternoon.timeIntervalSince1970, step: 3_600,
                                                      range: crossDay, calendar: calendar),
                       reference("MMMdjm", afternoon))
        // Day-and-larger steps label dates only, with a year for long ranges.
        XCTAssertEqual(WorkTimelineTimeAxis.tickLabel(midnight.timeIntervalSince1970, step: 86_400,
                                                      range: crossDay, calendar: calendar),
                       reference("MMMdj", midnight))
        let longRange = WorkTimelineInterval(lower: sameDay.lower, upper: sameDay.lower + 500 * 86_400)
        XCTAssertEqual(WorkTimelineTimeAxis.tickLabel(midnight.timeIntervalSince1970, step: 86_400,
                                                      range: longRange, calendar: calendar),
                       reference("yMMMd", midnight))
    }

    func testTickCountStaysBoundedByWidth() {
        for span in [1.0, 60, 1_800, 86_400, 604_800, 31_557_600] {
            let window = WorkTimelineInterval(lower: 1_789_234_567, upper: 1_789_234_567 + span)
            let ticks = WorkTimelineTimeAxis.ticks(in: window, width: 1000, minimumSpacing: 100)
            XCTAssertLessThanOrEqual(ticks.times.count, 14, "span \(span)")
            XCTAssertFalse(ticks.times.isEmpty, "span \(span)")
        }
    }
}
