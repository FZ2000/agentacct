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
