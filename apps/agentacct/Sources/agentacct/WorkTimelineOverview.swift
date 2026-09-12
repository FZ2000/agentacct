import SwiftUI

/// Geometry for view navigation only. It never changes evidence timestamps.
enum WorkTimelineRangeNavigation {
    static func focused(on record: WorkTimelineRecord) -> WorkTimelineInterval? {
        guard let start = record.start else { return nil }
        let end = record.end ?? start
        let context = max((end - start) * 0.15, 60)
        return .init(lower: start - context, upper: end + context)
    }

    /// Select only a visible recorded mark. An empty gap is not evidence.
    static func hitRecord(_ records: [WorkTimelineRecord], laneID: String, x: Double, width: Double,
                          within full: WorkTimelineInterval, tolerance: Double = 6) -> WorkTimelineRecord? {
        guard width > 0, x >= 0, x <= width else { return nil }
        let candidates = records.compactMap { record -> (WorkTimelineRecord, Double, Double)? in
            guard record.laneID == laneID, let start = record.start else { return nil }
            let left = full.fraction(start) * width
            if record.isDuration, let end = record.end {
                let right = full.fraction(end) * width
                let distance = max(left - x, x - right, 0)
                return distance <= tolerance ? (record, 1, max(right - left, 0)) : nil
            }
            let distance = abs(left - x)
            return distance <= tolerance ? (record, 0, distance) : nil
        }
        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.id < $1.0.id
        }.first?.0
    }

    static func selected(from start: Double, to end: Double, within full: WorkTimelineInterval) -> WorkTimelineInterval {
        let lower = min(max(min(start, end), full.lower), full.upper)
        let upper = min(max(max(start, end), lower + min(1, full.span)), full.upper)
        return .init(lower: min(lower, upper - min(1, full.span)), upper: upper)
    }

    static func shifted(_ window: WorkTimelineInterval, by delta: Double, within full: WorkTimelineInterval) -> WorkTimelineInterval {
        let span = min(window.span, full.span)
        let lower = min(max(window.lower + delta, full.lower), full.upper - span)
        return .init(lower: lower, upper: lower + span)
    }
}

enum WorkTimelineTimeAxis {
    static func preciseLabel(_ time: Double) -> String {
        let date = Date(timeIntervalSince1970: time)
        return "\(date.ISO8601Format(.init(includingFractionalSeconds: true))) · Unix \(time)"
    }
    static func showsDates(in range: WorkTimelineInterval, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(Date(timeIntervalSince1970: range.lower), inSameDayAs: Date(timeIntervalSince1970: range.upper))
    }
    static func label(_ time: Double, range: WorkTimelineInterval) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(showsDates(in: range) ? "MMMdjm" : "jms")
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    // MARK: Anchored ticks

    /// Candidate tick intervals in ascending order. Sub-day steps divide the
    /// hour or day evenly; larger steps count whole local days.
    private static let tickSteps: [Double] = [
        1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1_800,
        3_600, 7_200, 10_800, 21_600, 43_200,
        86_400, 172_800, 259_200, 604_800, 1_209_600, 2_592_000, 5_184_000,
        7_776_000, 15_724_800, 31_557_600,
    ]

    /// The smallest step whose on-screen spacing stays readable at this scale.
    static func tickStep(span: Double, width: Double, minimumSpacing: Double) -> Double {
        let span = span.isFinite && span > 0 ? span : 1
        let width = width.isFinite && width > 0 ? width : 1
        let spacing = minimumSpacing.isFinite && minimumSpacing > 0 ? minimumSpacing : 100
        let needed = span * spacing / width
        for step in tickSteps where step >= needed { return step }
        var step = tickSteps.last!
        while step < needed { step *= 4 }
        return step
    }

    /// Absolute tick times inside `window`. Sub-day steps anchor to epoch
    /// multiples; day-and-larger steps align to local midnights. Panning the
    /// window translates the same marks across the screen rather than
    /// redividing the window at fixed positions.
    static func ticks(in window: WorkTimelineInterval, width: Double, minimumSpacing: Double,
                      calendar: Calendar = .current) -> (step: Double, times: [Double]) {
        // A window crossing a day boundary needs wider, date-bearing labels.
        let dated = showsDates(in: window, calendar: calendar)
        let step = tickStep(span: window.span, width: width,
                            minimumSpacing: dated ? minimumSpacing * 1.5 : minimumSpacing)
        let lower = min(window.lower, window.upper), upper = max(window.lower, window.upper)
        guard lower.isFinite, upper.isFinite else { return (step, []) }
        let limit = max(2, Int(width / max(minimumSpacing, 1)) + 4)
        if step < 86_400 {
            var tick = (lower / step).rounded(.up) * step
            var times: [Double] = []
            while tick <= upper, times.count < limit {
                times.append(tick)
                tick += step
            }
            return (step, times)
        }
        // Day-level steps follow local midnights on an absolute lattice: the
        // phase is counted from the local epoch day, so panning the window
        // never shifts where marks land.
        let dayStep = max(1, Int((step / 86_400).rounded()))
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let lowerDay = calendar.startOfDay(for: Date(timeIntervalSince1970: lower))
        let elapsedDays = max(0, calendar.dateComponents([.day], from: reference, to: lowerDay).day ?? 0)
        var offset = (elapsedDays / dayStep) * dayStep
        var times: [Double] = []
        while times.count < limit {
            guard let day = calendar.date(byAdding: .day, value: offset, to: reference) else { break }
            let time = day.timeIntervalSince1970
            if time > upper { break }
            if time >= lower { times.append(time) }
            offset += dayStep
        }
        return (step, times)
    }

    /// A mark's label depends on its absolute time and the current step, never
    /// on the window position: panning keeps each mark's label unchanged, and
    /// reformatting happens only when zoom changes the step or day context.
    static func tickLabel(_ time: Double, step: Double, range: WorkTimelineInterval,
                          calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: time)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if step >= 86_400 {
            formatter.setLocalizedDateFormatFromTemplate(range.span > 400 * 86_400 ? "yMMMd" : "MMMdj")
        } else if showsDates(in: range, calendar: calendar) || date == calendar.startOfDay(for: date) {
            formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate(step < 60 ? "jms" : "jm")
        }
        return formatter.string(from: date)
    }
}

/// One coordinate system for the labels, Canvas marks, and pointer targets.
/// Font scaling must never move a label away from the lane that it selects.
struct WorkTimelineOverviewGeometry: Equatable {
    let laneHeight: CGFloat
    let verticalInset: CGFloat
    let labelWidth: CGFloat
    let markRadius: CGFloat
    let selectionRadius: CGFloat
    let hitTolerance: CGFloat
    let handleWidth: CGFloat
    let handleHeight: CGFloat

    init(dynamicTypeSize: DynamicTypeSize, systemScale: CGFloat = 1) {
        func scaled(_ base: CGFloat) -> CGFloat {
            WorkTypeScale.resolved(base: base, systemScaled: base * systemScale, dynamicTypeSize: dynamicTypeSize)
        }
        laneHeight = scaled(15)
        verticalInset = scaled(8)
        labelWidth = scaled(150)
        markRadius = scaled(2)
        selectionRadius = scaled(4)
        hitTolerance = scaled(6)
        handleWidth = scaled(3)
        handleHeight = scaled(14)
    }

    func height(laneCount: Int) -> CGFloat {
        CGFloat(max(laneCount, 1)) * laneHeight + verticalInset * 2
    }

    func laneCenter(at index: Int) -> CGFloat {
        verticalInset + (CGFloat(index) + 0.5) * laneHeight
    }

    func laneIndex(at y: CGFloat, laneCount: Int) -> Int? {
        guard laneCount > 0, y.isFinite, y >= verticalInset,
              y < verticalInset + CGFloat(laneCount) * laneHeight else { return nil }
        let index = Int(floor((y - verticalInset) / laneHeight))
        return abs(y - laneCenter(at: index)) <= hitTolerance ? index : nil
    }
}
