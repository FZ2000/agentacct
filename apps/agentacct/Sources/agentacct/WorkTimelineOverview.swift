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

struct WorkTimelineOverview: View {
    let projection: WorkTimelineProjection
    let window: WorkTimelineInterval?
    let selectedID: String?
    let onRange: (WorkTimelineInterval) -> Void
    let onSelect: (WorkTimelineRecord) -> Void
    @State private var dragWindow: WorkTimelineInterval?
    @State private var panning = false
    @State private var dragging = false
    @State private var showingSessionDetails = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var systemScale: CGFloat = 1

    private var lanes: [WorkTimelineLane] { Array(projection.lanes.prefix(6)) }
    private var metrics: WorkTimelineOverviewGeometry {
        .init(dynamicTypeSize: dynamicTypeSize, systemScale: systemScale)
    }
    private var height: CGFloat { metrics.height(laneCount: lanes.count) }

    var body: some View {
        if let full = projection.interval {
            VStack(alignment: .leading, spacing: 6) {
                overviewHeading
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lanes) { lane in
                            Text(lane.title).lineLimit(1).frame(height: metrics.laneHeight, alignment: .leading)
                                .help("\(lane.title) · \(lane.availability)")
                                .accessibilityLabel("\(lane.title), \(lane.availability)")
                        }
                    }
                    .padding(.vertical, metrics.verticalInset)
                    .workFont(.dataSmall).foregroundStyle(Theme.muted)
                    .frame(width: metrics.labelWidth, alignment: .leading)
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        let visible = window ?? full
                        let left = full.fraction(visible.lower) * width
                        let right = full.fraction(visible.upper) * width
                        ZStack(alignment: .topLeading) {
                            Canvas { context, size in
                                for (index, lane) in lanes.enumerated() {
                                    let y = metrics.laneCenter(at: index)
                                    var track = Path()
                                    track.move(to: CGPoint(x: 0, y: y)); track.addLine(to: CGPoint(x: size.width, y: y))
                                    let hasDated = projection.records.contains { $0.laneID == lane.id && $0.start != nil }
                                    context.stroke(track, with: .color(Theme.hairline), style: StrokeStyle(lineWidth: 1, dash: hasDated ? [] : [3, 3]))
                                    for record in projection.records where record.laneID == lane.id {
                                        guard let start = record.start else { continue }
                                        let x = full.fraction(start) * size.width
                                        let end = full.fraction(record.end ?? start) * size.width
                                        let tint = record.isCurrentFailure ? Theme.coral : (record.kind == .step ? Theme.accent : Theme.muted)
                                        if record.isDuration {
                                            let bar = Path(roundedRect: CGRect(x: x, y: y - metrics.markRadius, width: max(end - x, metrics.markRadius), height: metrics.markRadius * 2), cornerRadius: metrics.markRadius)
                                            context.fill(bar, with: .color(tint.opacity(record.superseded ? 0.25 : 0.5)))
                                        } else {
                                            context.fill(Path(ellipseIn: CGRect(x: x - metrics.markRadius, y: y - metrics.markRadius, width: metrics.markRadius * 2, height: metrics.markRadius * 2)), with: .color(tint))
                                        }
                                        if record.id == selectedID {
                                            context.stroke(Path(ellipseIn: CGRect(x: x - metrics.selectionRadius, y: y - metrics.selectionRadius, width: metrics.selectionRadius * 2, height: metrics.selectionRadius * 2)), with: .color(Theme.ink), lineWidth: 1.5)
                                        }
                                    }
                                }
                            }
                            Rectangle().fill(Theme.canvas.opacity(0.65)).frame(width: left)
                            Rectangle().fill(Theme.canvas.opacity(0.65)).frame(width: max(width - right, 0)).offset(x: right)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.accent.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                                .frame(width: max(right - left, 2)).offset(x: left)
                            Capsule().fill(Theme.accent).frame(width: metrics.handleWidth, height: metrics.handleHeight).offset(x: left, y: (height - metrics.handleHeight) / 2)
                            Capsule().fill(Theme.accent).frame(width: metrics.handleWidth, height: metrics.handleHeight).offset(x: max(right - metrics.handleWidth, 0), y: (height - metrics.handleHeight) / 2)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !dragging {
                                    dragging = true
                                    dragWindow = visible
                                    panning = visible.span < full.span * 0.98 && value.startLocation.x > left + 5 && value.startLocation.x < right - 5
                                }
                                guard abs(value.translation.width) > 3 else { return }
                                if panning, let dragWindow {
                                    onRange(WorkTimelineRangeNavigation.shifted(dragWindow, by: value.translation.width / width * full.span, within: full))
                                } else {
                                    let start = full.lower + value.startLocation.x / width * full.span
                                    let end = full.lower + value.location.x / width * full.span
                                    onRange(WorkTimelineRangeNavigation.selected(from: start, to: end, within: full))
                                }
                            }
                            .onEnded { value in
                                if abs(value.translation.width) <= 3 {
                                    if let index = metrics.laneIndex(at: value.location.y, laneCount: lanes.count),
                                       let record = WorkTimelineRangeNavigation.hitRecord(projection.records,
                                           laneID: lanes[index].id, x: value.location.x, width: width, within: full,
                                           tolerance: metrics.hitTolerance) {
                                        onSelect(record)
                                    }
                                }
                                dragging = false; dragWindow = nil
                            })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Session time overview")
                        .accessibilityValue("\(projection.lanes.count) sessions; \(projection.records.count) loaded records. Range controls below provide keyboard navigation.")
                    }
                }.frame(height: height)
                let undated = projection.records.filter { $0.start == nil }.count
                if undated > 0 {
                    Text("\(undated) undated records").workFont(.caption).foregroundStyle(Theme.muted)
                }
                if projection.lanes.count > lanes.count {
                    Text("Overview shows the first \(lanes.count) lanes. All \(projection.lanes.count) lanes remain in the detailed view.")
                        .workFont(.caption).foregroundStyle(Theme.muted)
                }
                sessionDetails
            }
            .padding(10).background(Theme.canvas, in: RoundedRectangle(cornerRadius: Metrics.radius))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work.timeline.overview")
        }
    }

    private var overviewHeading: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 8) {
                Text("Session overview").workFont(.captionSemibold)
                Text("\(projection.lanes.count) lanes").workFont(.caption).foregroundStyle(Theme.muted)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            ContextHelp(title: "Navigate the time range",
                message: "Drag across the overview to select a time range. Drag inside an existing range to move it. Earlier, Later and zoom controls provide keyboard alternatives. Undated records stay outside the time axis.",
                identifier: "work.timeline.overview.help")
        }
    }

    private var sessionDetails: some View {
        DisclosureGroup("Session names and lineage", isExpanded: $showingSessionDetails) {
            VStack(alignment: .leading, spacing: Space.l) {
                ForEach(projection.lanes) { lane in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(lane.title).workFont(.rowLabel).foregroundStyle(Theme.ink)
                        Text(lane.id).workFont(.dataSmall).foregroundStyle(Theme.muted)
                        Text(lane.lineage).workFont(.caption).foregroundStyle(Theme.muted)
                        Text(lane.availability).workFont(.caption).foregroundStyle(Theme.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            .padding(.top, Space.m)
        }
        .workFont(.captionSemibold)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.timeline.session-identities")
    }
}
