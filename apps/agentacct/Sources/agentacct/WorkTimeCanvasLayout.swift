import CoreGraphics
import Foundation

/// Pure geometry for a time canvas with cards above and below one shared axis.
/// Card width is reading space, never elapsed execution time. `timeBounds`
/// retains the recorded extent independently of the card's collision placement.
/// Packing covers every loaded dated record and positions are anchored to
/// absolute time, so panning only translates items; grouping changes require a
/// scale, width or record-set change.
struct WorkTimeCanvasLayout {
    struct Item: Identifiable, Equatable {
        let id: String
        let recordIDs: [String]
        let frame: CGRect
        let anchorX: Double
        let isAbove: Bool
        let timeBounds: WorkTimelineInterval

        var count: Int { recordIDs.count }
        var isCluster: Bool { count > 1 }
    }

    let items: [Item]
    let window: WorkTimelineInterval
    let axisY: Double
    let cardWidth: Double
    let cardHeight: Double
    let bandCountPerSide: Int
    let visibleRecordCount: Int
    let undatedRecordIDs: [String]

    private static let gap = 12.0
    private static let upperAxisClearance = 12.0
    private static let outerMargin = 8.0

    init(
        records: [WorkTimelineRecord],
        window: WorkTimelineInterval,
        width: Double,
        height: Double,
        textScale: Double = 1
    ) {
        let window = Self.normalizedDomain(window)
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let scale = Self.normalizedScale(textScale)
        let cardHeight = 80 * scale
        let cardWidth = min(200 * scale, width)
        let lowerAxisClearance = 44 * scale
        let axisY = min(height, max(0, (height - lowerAxisClearance + Self.upperAxisClearance) / 2))
        let availableHeight = max(0, min(
            axisY - Self.upperAxisClearance - Self.outerMargin,
            height - axisY - lowerAxisClearance - Self.outerMargin
        ))
        let bands = Int(min(2, floor((availableHeight + Self.gap + 0.000001) / (cardHeight + Self.gap))))

        self.window = window
        self.axisY = axisY
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.bandCountPerSide = bands

        // Placement packs every loaded dated record, not just the records
        // inside the window: grouping and band assignment then depend only on
        // the records and the current scale, so panning translates cards
        // without rearranging them. Rendering culls far-offscreen items.
        var seen = Set<String>()
        var undated: [String] = []
        var visibleCount = 0
        var candidates: [Group] = []
        for record in records where seen.insert(record.id).inserted {
            guard let start = WorkTimelineProjection.validTime(record.start) else {
                undated.append(record.id)
                continue
            }
            let end = max(start, WorkTimelineProjection.validTime(record.end) ?? start)
            if start <= window.upper, end >= window.lower { visibleCount += 1 }
            candidates.append(Group(recordIDs: [record.id], lower: start, upper: end))
        }
        candidates.sort {
            $0.lower == $1.lower ? $0.recordIDs[0] < $1.recordIDs[0] : $0.lower < $1.lower
        }
        self.visibleRecordCount = visibleCount
        self.undatedRecordIDs = undated.sorted()

        guard width > 0, bands > 0, !candidates.isEmpty else {
            self.items = []
            return
        }

        self.items = Self.pack(
            candidates, window: window, width: width, axisY: axisY,
            cardWidth: cardWidth, cardHeight: cardHeight,
            lowerAxisClearance: lowerAxisClearance, slots: bands * 2
        )
    }

    /// Items intersecting the viewport plus one card of margin, plus any item
    /// whose recorded extent crosses the window (its span line runs through
    /// even when its card sits offscreen). Culling is presentation-only:
    /// placement and grouping never depend on it, so panning cannot rearrange
    /// or regroup cards at the viewport edges.
    func items(visibleIn width: Double) -> [Item] {
        guard width.isFinite else { return items }
        let margin = cardWidth + Self.gap
        return items.filter {
            ($0.frame.maxX >= -margin && $0.frame.minX <= width + margin)
                || ($0.timeBounds.upper >= window.lower && $0.timeBounds.lower <= window.upper)
        }
    }

    /// Enough height for one readable band per side plus the time-label strip.
    /// The view can grow its canvas at large text sizes instead of clipping.
    static func minimumHeight(textScale: Double = 1) -> Double {
        let scale = normalizedScale(textScale)
        return 160 * scale + 44 * scale + upperAxisClearance + 2 * outerMargin
    }

    /// Follow the newest actual timestamp, not the padded domain's empty tail.
    /// A small trailing margin keeps the latest mark clear of the right edge.
    static func latestWindow(
        within full: WorkTimelineInterval,
        latest: Double?,
        span: Double = 1800
    ) -> WorkTimelineInterval {
        let full = normalizedDomain(full)
        let span = span.isFinite && span > 0 ? span : 1800
        let duration = min(span, full.upper - full.lower)
        let end: Double
        if let latest = WorkTimelineProjection.validTime(latest),
           latest >= full.lower, latest <= full.upper {
            end = min(full.upper, latest + min(duration * 0.08, 60))
        } else {
            end = full.upper
        }
        return clampedWindow(.init(lower: end - duration, upper: end), to: full)
    }

    /// Constrain a requested window to the domain, preserving its span where
    /// possible. Invalid domains become [0, 1]; a finite point domain expands
    /// by one second when representable. Invalid windows show the full domain.
    static func clampedWindow(
        _ window: WorkTimelineInterval,
        to full: WorkTimelineInterval,
        minimumSpan: Double = 1
    ) -> WorkTimelineInterval {
        let full = normalizedDomain(full)
        guard window.lower.isFinite, window.upper.isFinite else { return full }
        let lower = min(window.lower, window.upper)
        let upper = max(window.lower, window.upper)
        let fullSpan = full.upper - full.lower
        let minimum = minimumSpan.isFinite && minimumSpan > 0 ? minimumSpan : 1
        let span = min(fullSpan, max(minimum, upper - lower))
        let start = min(max(lower, full.lower), full.upper - span)
        return WorkTimelineInterval(lower: start, upper: min(full.upper, start + span))
    }

    /// Positive seconds move toward later records. Saturation at the domain
    /// boundaries avoids overflow even for an extreme finite input delta.
    static func pannedWindow(
        _ window: WorkTimelineInterval,
        by delta: Double,
        within full: WorkTimelineInterval
    ) -> WorkTimelineInterval {
        let full = normalizedDomain(full)
        let current = clampedWindow(window, to: full)
        guard delta.isFinite else { return current }
        let span = current.upper - current.lower
        if delta >= full.upper - current.upper {
            return .init(lower: full.upper - span, upper: full.upper)
        }
        if delta <= full.lower - current.lower {
            return .init(lower: full.lower, upper: full.lower + span)
        }
        return .init(lower: current.lower + delta, upper: current.upper + delta)
    }

    /// A factor greater than one zooms in. Keep the time at `anchorFraction`
    /// under the same viewport position unless a domain edge requires clamping.
    static func zoomedWindow(
        _ window: WorkTimelineInterval,
        factor: Double,
        anchorFraction: Double,
        within full: WorkTimelineInterval,
        minimumSpan: Double = 1
    ) -> WorkTimelineInterval {
        let full = normalizedDomain(full)
        let current = clampedWindow(window, to: full, minimumSpan: minimumSpan)
        guard factor.isFinite, factor > 0 else { return current }
        let fraction = anchorFraction.isFinite ? min(max(anchorFraction, 0), 1) : 0.5
        let minimum = minimumSpan.isFinite && minimumSpan > 0 ? minimumSpan : 1
        let oldSpan = current.upper - current.lower
        let newSpan = min(full.upper - full.lower, max(minimum, oldSpan / factor))
        let anchor = current.lower + oldSpan * fraction
        let lower = anchor - newSpan * fraction
        return clampedWindow(.init(lower: lower, upper: lower + newSpan), to: full, minimumSpan: minimumSpan)
    }

    /// Zoom keeping an absolute anchor time fixed. Surfaces whose pointer
    /// position is expressed against the full domain (the overview) convert to
    /// the window-relative fraction here. An anchor outside the window clamps
    /// to the nearest edge.
    static func zoomedWindow(
        _ window: WorkTimelineInterval,
        factor: Double,
        anchorTime: Double,
        within full: WorkTimelineInterval,
        minimumSpan: Double = 1
    ) -> WorkTimelineInterval {
        let current = clampedWindow(window, to: full, minimumSpan: minimumSpan)
        let span = current.upper - current.lower
        let fraction = anchorTime.isFinite && span > 0 ? (anchorTime - current.lower) / span : 0.5
        return zoomedWindow(current, factor: factor, anchorFraction: fraction, within: full, minimumSpan: minimumSpan)
    }

    private struct Group {
        var recordIDs: [String]
        var lower: Double
        var upper: Double
    }

    private struct PlacedGroup {
        var group: Group
        let frame: CGRect
        let anchorX: Double
        let isAbove: Bool
    }

    private static func pack(
        _ groups: [Group], window: WorkTimelineInterval, width: Double,
        axisY: Double, cardWidth: Double, cardHeight: Double,
        lowerAxisClearance: Double, slots: Int
    ) -> [Item] {
        var ends = Array(repeating: -Double.infinity, count: slots)
        var lastPlaced = Array(repeating: -1, count: slots)
        var placed: [PlacedGroup] = []
        for group in groups {
            let anchorX = anchor(group.lower, window: window, width: width)
            // Cards are not clamped to the viewport: a partially offscreen card
            // keeps its time-true position and slides under the edge while
            // panning, instead of jumping to or away from the boundary.
            let x = anchorX - cardWidth / 2
            guard let slot = ends.indices.first(where: { x >= ends[$0] + gap }) else {
                // All bands are occupied. Extend the nearest last card's
                // membership without moving earlier cards or repacking them.
                // This costs at most four comparisons per incoming record.
                var target = lastPlaced[0]
                for candidate in lastPlaced.dropFirst() {
                    if anchorX - placed[candidate].anchorX < anchorX - placed[target].anchorX {
                        target = candidate
                    }
                }
                placed[target].group.recordIDs.append(contentsOf: group.recordIDs)
                placed[target].group.upper = max(placed[target].group.upper, group.upper)
                continue
            }
            let above = slot.isMultiple(of: 2)
            let band = Double(slot / 2)
            let offset = (above ? upperAxisClearance : lowerAxisClearance) + band * (cardHeight + gap)
            let y = above ? axisY - offset - cardHeight : axisY + offset
            let frame = CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
            placed.append(PlacedGroup(group: group, frame: frame, anchorX: anchorX, isAbove: above))
            lastPlaced[slot] = placed.count - 1
            ends[slot] = frame.maxX
        }
        return placed.map {
            Item(
                id: stableID($0.group.recordIDs), recordIDs: $0.group.recordIDs,
                frame: $0.frame, anchorX: $0.anchorX, isAbove: $0.isAbove,
                timeBounds: .init(lower: $0.group.lower, upper: $0.group.upper)
            )
        }
    }

    /// The unclipped linear time-to-position map. Offscreen times produce
    /// positions outside `0...width`; that is what keeps relative placement
    /// independent of the window's position within the full domain.
    private static func anchor(_ time: Double, window: WorkTimelineInterval, width: Double) -> Double {
        (time - window.lower) / (window.upper - window.lower) * width
    }

    private static func stableID(_ members: [String]) -> String {
        guard members.count > 1 else { return "record:\(members[0])" }
        // Stable presentation identity, not a claim that separate source events
        // are identical. Length-prefix each member to avoid delimiter ambiguity.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for id in members.sorted() {
            for byte in "\(id.utf8.count):\(id)".utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        return "cluster:\(members.count):\(String(hash, radix: 16))"
    }

    private static func normalizedDomain(_ interval: WorkTimelineInterval) -> WorkTimelineInterval {
        guard interval.lower.isFinite, interval.upper.isFinite else { return .init(lower: 0, upper: 1) }
        let lower = min(interval.lower, interval.upper), upper = max(interval.lower, interval.upper)
        guard (upper - lower).isFinite else { return .init(lower: 0, upper: 1) }
        if upper > lower { return .init(lower: lower, upper: upper) }
        if lower + 1 > lower, (lower + 1).isFinite { return .init(lower: lower, upper: lower + 1) }
        return .init(lower: 0, upper: 1)
    }

    private static func normalizedScale(_ scale: Double) -> Double {
        scale.isFinite && scale > 0 ? min(scale, 8) : 1
    }
}
