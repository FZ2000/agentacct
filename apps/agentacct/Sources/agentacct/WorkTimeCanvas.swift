import AppKit
import SwiftUI

/// A viewport into recorded time. Card positions describe timestamps; neither
/// their placement nor their connecting stems claims an execution dependency.
struct WorkTimeCanvas<Detail: View>: View {
    let records: [WorkTimelineRecord]
    let full: WorkTimelineInterval
    let window: WorkTimelineInterval
    let selectedRecord: WorkTimelineRecord?
    private var selectedID: String? { selectedRecord?.id }
    let onWindow: (WorkTimelineInterval) -> Void
    let onSelect: (WorkTimelineRecord) -> Void
    let onDismiss: () -> Void
    let onHold: () -> Void
    var dismissRequest = 0
    var focusRecordID: String? = nil
    var focusRequest = 0
    var compact = false
    let detail: (WorkTimelineRecord) -> Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1
    @State private var expandedCluster: String?
    @State private var detailOwnerID: String?
    @State private var lastTriggerID: String?
    @State private var chooserPosition: String?
    @State private var hoveredID: String?
    @FocusState private var focusedItem: String?

    private var scale: Double {
        Double(WorkTypeScale.resolved(base: 1, systemScaled: systemScale, dynamicTypeSize: dynamicTypeSize))
    }
    private var canvasHeight: Double { max(compact ? 280 : 420, WorkTimeCanvasLayout.minimumHeight(textScale: scale)) }

    var body: some View {
        VStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                WorkTimeWindowScroller(records: records, full: full, window: window, onWindow: onWindow)
            }
            GeometryReader { geometry in
                let width = Double(geometry.size.width)
                let indexedRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let layout = WorkTimeCanvasLayout(records: records, window: window,
                    width: width, height: canvasHeight, textScale: scale)
                input(layout: layout, width: width) {
                    ZStack(alignment: .topLeading) {
                    Theme.canvas
                    drawing(layout: layout, width: width, indexedRecords: indexedRecords).allowsHitTesting(false)
                    axisLabels(width: width, axisY: layout.axisY).allowsHitTesting(false)
                    ForEach(layout.items) { item in
                        itemButton(item, indexedRecords: indexedRecords)
                            .frame(width: item.frame.width, height: item.frame.height)
                            .position(x: item.frame.midX, y: item.frame.midY)
                    }
                    if layout.visibleRecordCount == 0 {
                        Text("No activity in this time window")
                            .workFont(.body).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).offset(y: layout.axisY - 64 * scale)
                            .allowsHitTesting(false)
                    }
                    }
                }.clipped()
                .task(id: FocusTarget(request: focusRequest, recordID: focusRecordID, ownerID: detailOwnerID)) {
                    guard focusRecordID != nil, detailOwnerID == nil else { return }
                    // Native popover dismissal restores its window's responder
                    // first. Restore the event after that transition completes.
                    focusedItem = nil
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, detailOwnerID == nil else { return }
                    focus(in: layout)
                }
                .onChange(of: dismissRequest) { _, _ in
                    expandedCluster = nil
                    detailOwnerID = nil
                }
            }
            .frame(height: canvasHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Activity timeline")
            .accessibilityIdentifier("work.timeline.canvas")
            if !dynamicTypeSize.isAccessibilitySize {
                WorkTimeWindowScroller(records: records, full: full, window: window, onWindow: onWindow)
            }
        }
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.hairline))
    }

    private func input<Content: View>(layout: WorkTimeCanvasLayout, width: Double, @ViewBuilder content: () -> Content) -> some View {
        WorkTimeCanvasInput(interactiveRegions: layout.items.map(\.frame),
            onPan: { pixels in
                onWindow(WorkTimeCanvasLayout.pannedWindow(window, by: -pixels / max(width, 1) * window.span, within: full))
            },
            onZoom: { factor, anchor in
                onWindow(WorkTimeCanvasLayout.zoomedWindow(window, factor: factor, anchorFraction: anchor, within: full))
            },
            onEdge: { latest in
                onWindow(WorkTimeCanvasLayout.pannedWindow(window,
                    by: latest ? full.upper - window.upper : full.lower - window.lower, within: full))
            },
            onDismiss: onDismiss,
            onBackgroundClick: onDismiss,
            accessibilityValue: "\(WorkTimelineTimeAxis.label(window.lower, range: window)) to \(WorkTimelineTimeAxis.label(window.upper, range: window))",
            content: content).renderingSurface
    }

    private func drawing(layout: WorkTimeCanvasLayout, width: Double, indexedRecords: [String: WorkTimelineRecord]) -> some View {
        Canvas { context, size in
            var spine = Path()
            spine.move(to: CGPoint(x: 0, y: layout.axisY))
            spine.addLine(to: CGPoint(x: width, y: layout.axisY))
            context.stroke(spine, with: .color(Theme.muted.opacity(0.65)), lineWidth: 1)
            for tick in ticks(width: width) {
                let x = window.fraction(tick) * width
                var line = Path()
                line.move(to: CGPoint(x: x, y: layout.axisY - 4))
                line.addLine(to: CGPoint(x: x, y: layout.axisY + 4))
                context.stroke(line, with: .color(Theme.muted), lineWidth: 1)
            }
            for item in layout.items {
                let selected = selectedID.map(item.recordIDs.contains) ?? false
                let emphasized = selected || hoveredID == item.id || focusedItem == item.id
                let tint = item.recordIDs.contains { id in indexedRecords[id]?.isCurrentFailure == true }
                    ? Theme.coral : Theme.accent
                let edge = item.isAbove ? item.frame.maxY : item.frame.minY
                var stem = Path()
                stem.move(to: CGPoint(x: item.anchorX, y: layout.axisY))
                stem.addLine(to: CGPoint(x: item.anchorX, y: edge))
                context.stroke(stem, with: .color(tint.opacity(emphasized ? 0.85 : 0.32)), lineWidth: emphasized ? 2 : 1)
                if !item.isCluster, let id = item.recordIDs.first, let record = indexedRecords[id], record.isDuration {
                    let x1 = window.fraction(record.start!) * width
                    let x2 = window.fraction(record.end!) * width
                    let y = layout.axisY + (item.isAbove ? -5.0 : 5.0)
                    var span = Path()
                    span.move(to: CGPoint(x: x1, y: y)); span.addLine(to: CGPoint(x: x2, y: y))
                    context.stroke(span, with: .color(tint.opacity(emphasized ? 0.9 : 0.35)), lineWidth: 3)
                }
                if item.timeBounds.lower < window.lower {
                    var continuation = Path()
                    continuation.move(to: CGPoint(x: 7, y: layout.axisY - 4))
                    continuation.addLine(to: CGPoint(x: 2, y: layout.axisY))
                    continuation.addLine(to: CGPoint(x: 7, y: layout.axisY + 4))
                    context.stroke(continuation, with: .color(tint), lineWidth: 2)
                } else {
                    let radius = item.isCluster ? 5.0 : 3.5
                    context.fill(Path(ellipseIn: CGRect(x: item.anchorX - radius, y: layout.axisY - radius,
                        width: radius * 2, height: radius * 2)), with: .color(tint))
                }
                if item.timeBounds.upper > window.upper {
                    var continuation = Path()
                    continuation.move(to: CGPoint(x: width - 7, y: layout.axisY - 4))
                    continuation.addLine(to: CGPoint(x: width - 2, y: layout.axisY))
                    continuation.addLine(to: CGPoint(x: width - 7, y: layout.axisY + 4))
                    context.stroke(continuation, with: .color(tint), lineWidth: 2)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func ticks(width: Double) -> [Double] {
        let count = max(2, min(7, Int(width / (190 * scale))))
        return (0..<count).map { window.lower + window.span * Double($0) / Double(count - 1) }
    }

    private func axisLabels(width: Double, axisY: Double) -> some View {
        HStack(spacing: 0) {
            let values = ticks(width: width)
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                if index > 0 { Spacer(minLength: 0) }
                Text(axisLabel(value, includeDate: index == 0))
                    .workFont(.dataSmall).foregroundStyle(Theme.muted)
                    .fixedSize().background(Theme.canvas)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width)
        .offset(y: axisY + 12)
        .accessibilityHidden(true)
    }

    private func axisLabel(_ time: Double, includeDate: Bool) -> String {
        let formatter = DateFormatter()
        let showsDate = includeDate || WorkTimelineTimeAxis.showsDates(in: window)
        formatter.setLocalizedDateFormatFromTemplate(showsDate ? "MMMdjm" : (window.span >= 60 ? "jm" : "jms"))
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    private func itemButton(_ item: WorkTimeCanvasLayout.Item, indexedRecords: [String: WorkTimelineRecord]) -> some View {
        let members = item.recordIDs.compactMap { indexedRecords[$0] }
        let selected = selectedID.map(item.recordIDs.contains) ?? false
        return Button { activate(item, members: members) } label: {
            VStack(alignment: .leading, spacing: 2) {
                if item.isCluster {
                    Text("\(members.count) records").workFont(.rowLabel).foregroundStyle(Theme.ink)
                    let sessionCount = Set(members.map(\.laneID)).count
                    Text(sessionCount == 1 ? (members.first?.laneTitle ?? "Activity") : "\(sessionCount) sessions")
                        .workFont(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    let failures = members.filter(\.isCurrentFailure).count
                    if failures > 0 {
                        Label("\(failures) failed", systemImage: "exclamationmark.circle")
                            .workFont(.caption).foregroundStyle(Theme.coral)
                    }
                } else if let record = members.first {
                    Text(record.laneTitle).workFont(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(record.title).workFont(.rowLabel).foregroundStyle(Theme.ink).lineLimit(2)
                    Label(record.resultLabel, systemImage: symbol(record))
                        .workFont(.caption).foregroundStyle(tint(record)).lineLimit(1)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(selected ? Theme.selected : Theme.card,
                in: RoundedRectangle(cornerRadius: Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius)
                .strokeBorder(selected ? Theme.accent : Theme.cardLine, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle(focusInset: 2))
        .focusable()
        .focused($focusedItem, equals: item.id)
        .onKeyPress(.space) { activate(item, members: members); return .handled }
        .onKeyPress(.return) { activate(item, members: members); return .handled }
        .onHover { hoveredID = $0 ? item.id : nil }
        .help(members.count == 1 ? "\(members[0].title)\n\(members[0].laneTitle)\n\(members[0].source)" : "Inspect these \(members.count) records or zoom into their time range")
        .accessibilityIdentifier(item.isCluster ? "work.timeline.cluster.\(item.id)" : "work.timeline.record.\(item.recordIDs[0])")
        .accessibilityLabel(item.isCluster ? "\(members.count) records in a time group" : "\(members.first?.title ?? "Activity"), \(members.first?.resultLabel ?? ""), \(members.first?.laneTitle ?? ""), \(members.first?.source ?? ""), \(members.first?.start.map { WorkTimelineTimeAxis.preciseLabel($0) } ?? "Time unavailable")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onKeyPress(.escape) {
            expandedCluster = nil
            detailOwnerID = nil
            onDismiss()
            return .handled
        }
        .popover(isPresented: Binding(
            get: { !SnapshotMode.boundsScrollContentToViewport && (expandedCluster == item.id || (detailOwnerID == item.id && selectedRecord != nil)) },
            set: { showing in
                if !showing {
                    if expandedCluster == item.id { expandedCluster = nil }
                    if detailOwnerID == item.id { detailOwnerID = nil; onDismiss() }
                }
            })) {
            if detailOwnerID == item.id, let record = selectedRecord {
                WorkRecordPopover(width: CGFloat(min(600, 420 * scale)), maximumHeight: 560) {
                    VStack(alignment: .leading, spacing: 0) {
                        if item.isCluster {
                            Button { onDismiss() } label: {
                                Label("Back to \(members.count) records", systemImage: "chevron.left")
                            }.buttonStyle(QuietButtonStyle(horizontalPadding: 8)).padding(8)
                            .accessibilityIdentifier("work.timeline.cluster.back")
                            Divider().overlay(Theme.hairline)
                        }
                        detail(record)
                    }
                }
                .environment(\.dynamicTypeSize, dynamicTypeSize)
            } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(members.count) records").workFont(.titleCard)
                    Spacer()
                    Button("Zoom here") {
                        expandedCluster = nil
                        let padding = max(item.timeBounds.span * 0.15, 1)
                        onWindow(WorkTimeCanvasLayout.clampedWindow(.init(lower: item.timeBounds.lower - padding,
                            upper: item.timeBounds.upper + padding), to: full))
                    }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                    .disabled(item.timeBounds.span <= 1 || item.timeBounds.span >= window.span * 0.9)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(members) { record in
                            Button {
                                onSelect(record)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title).workFont(.rowLabel)
                                    Text("\(record.laneTitle) · \(record.resultLabel)")
                                        .workFont(.caption).foregroundStyle(tint(record))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }.buttonStyle(SurfaceButtonStyle())
                            .accessibilityIdentifier("work.timeline.record.\(record.id)")
                        }
                    }.scrollTargetLayout()
                }.scrollPosition(id: $chooserPosition).frame(maxHeight: 300)
            }.padding(16).frame(width: min(560, 340 * scale))
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
        }
    }

    private func activate(_ item: WorkTimeCanvasLayout.Item, members: [WorkTimelineRecord]) {
        detailOwnerID = item.id
        lastTriggerID = item.id
        if item.isCluster { onHold(); onDismiss(); expandedCluster = item.id }
        else if let record = members.first { expandedCluster = nil; onSelect(record) }
    }

    private struct FocusTarget: Equatable {
        let request: Int
        let recordID: String?
        let ownerID: String?
    }

    private func focus(in layout: WorkTimeCanvasLayout) {
        guard let focusRecordID else { return }
        focusedItem = layout.items.first { $0.recordIDs.contains(focusRecordID) }?.id
            ?? layout.items.first { $0.id == lastTriggerID }?.id
    }

    private func tint(_ record: WorkTimelineRecord) -> Color {
        if record.superseded || record.disposition != nil { return Theme.muted }
        return record.isCurrentFailure ? Theme.coral : (record.kind == .step ? Theme.accent : Theme.ink)
    }
    private func symbol(_ record: WorkTimelineRecord) -> String {
        if record.superseded { return "clock.arrow.circlepath" }
        if record.kind == .step { return "circle.inset.filled" }
        return record.result == "passed" ? "checkmark.circle" : (record.isCurrentFailure ? "xmark.circle" : "circle")
    }
}

/// Scrollbar-like overview: its body pans the window, its edges change scale.
/// The small histogram counts dated records, never elapsed work or utilization.
private struct WorkTimeWindowScroller: View {
    let records: [WorkTimelineRecord]
    let full: WorkTimelineInterval
    let window: WorkTimelineInterval
    let onWindow: (WorkTimelineInterval) -> Void
    @State private var dragStart: WorkTimelineInterval?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 40, 1)
            let left = full.fraction(window.lower) * width
            let right = full.fraction(window.upper) * width
            WorkTimeCanvasInput(interactiveRegions: [CGRect(x: 0, y: 0, width: geometry.size.width, height: 32)],
                allowVerticalScroll: true,
                onPan: { pixels in
                    onWindow(WorkTimeCanvasLayout.pannedWindow(window, by: -pixels / width * full.span, within: full))
                }, onZoom: { factor, anchor in
                    onWindow(WorkTimeCanvasLayout.zoomedWindow(window, factor: factor, anchorFraction: anchor, within: full))
                }, accessibilityIdentifier: "work.timeline.overview.navigation") {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.hairline.opacity(0.5))
                Canvas { context, size in
                    var bins = [Int](repeating: 0, count: max(1, Int(size.width / 5)))
                    for record in records {
                        guard let time = record.start else { continue }
                        bins[min(Int(full.fraction(time) * Double(bins.count)), bins.count - 1)] += 1
                    }
                    let peak = max(bins.max() ?? 0, 1)
                    for (index, value) in bins.enumerated() where value > 0 {
                        let h = max(3, Double(value) / Double(peak) * 20)
                        context.fill(Path(CGRect(x: Double(index) * size.width / Double(bins.count), y: size.height - h - 3,
                            width: max(size.width / Double(bins.count) - 1, 1), height: h)), with: .color(Theme.muted.opacity(0.4)))
                    }
                }.allowsHitTesting(false)
                Button { onWindow(window) } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.accent.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent.opacity(0.7)))
                        .contentShape(Rectangle())
                }
                    .buttonStyle(SurfaceButtonStyle())
                    .frame(width: max(right - left, 2)).offset(x: left)
                    .simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("work-time-overview")).onChanged { value in
                        let start = dragStart ?? window; dragStart = start
                        onWindow(WorkTimeCanvasLayout.pannedWindow(start, by: value.translation.width / width * full.span, within: full))
                    }.onEnded { _ in dragStart = nil })
                    .onHover { ($0 ? NSCursor.openHand : NSCursor.arrow).set() }
                    .accessibilityRepresentation { accessibleRangeControl(edge: nil) }
                    .help("Drag to move through time. Drag either edge to change the visible time span.")
                handle(at: left, isStart: true, width: width)
                handle(at: right, isStart: false, width: width)
            }
            .frame(width: width, height: 32).coordinateSpace(name: "work-time-overview").padding(.horizontal, 20)
            }.renderingSurface
        }
        .frame(height: 40)
    }

    private func handle(at x: Double, isStart: Bool, width: Double) -> some View {
        Button { onWindow(window) } label: {
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                .frame(width: 4, height: 18).frame(width: 18, height: 32)
                .contentShape(Rectangle())
        }
            .buttonStyle(SurfaceButtonStyle())
            .offset(x: x + (isStart ? -19 : 1))
            .simultaneousGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("work-time-overview")).onChanged { value in
                let start = dragStart ?? window; dragStart = start
                let delta = value.translation.width / width * full.span
                let lower = isStart ? min(max(start.lower + delta, full.lower), start.upper - min(1, full.span)) : start.lower
                let upper = isStart ? start.upper : max(min(start.upper + delta, full.upper), start.lower + min(1, full.span))
                onWindow(.init(lower: lower, upper: upper))
            }.onEnded { _ in dragStart = nil })
            .onHover { ($0 ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .accessibilityRepresentation { accessibleRangeControl(edge: isStart) }
            .help(isStart ? "Drag to change the start of the time window" : "Drag to change the end of the time window")
    }

    /// The graphical range exposes native slider values and standard
    /// increment/decrement actions to keyboard and accessibility navigation.
    private func accessibleRangeControl(edge: Bool?) -> some View {
        let minimum = min(1, full.span)
        let lower = edge == false ? window.lower + minimum : full.lower
        let upper = edge == true ? window.upper - minimum
            : (edge == false ? full.upper : full.upper - window.span)
        let value = Binding<Double>(
            get: { edge == false ? window.upper : window.lower },
            set: { value in
                if let edge {
                    onWindow(.init(lower: edge ? value : window.lower, upper: edge ? window.upper : value))
                } else {
                    onWindow(WorkTimeCanvasLayout.pannedWindow(window, by: value - window.lower, within: full))
                }
            })
        return Slider(value: value, in: lower...max(lower, upper))
            .accessibilityLabel(edge == nil ? "Visible time window" : (edge == true ? "Start of visible time window" : "End of visible time window"))
            .accessibilityValue(edge == nil
                ? "\(WorkTimelineTimeAxis.label(window.lower, range: window)) to \(WorkTimelineTimeAxis.label(window.upper, range: window))"
                : WorkTimelineTimeAxis.label(edge == true ? window.lower : window.upper, range: window))
            .accessibilityIdentifier(edge == nil ? "work.timeline.window" : (edge == true ? "work.timeline.window.start" : "work.timeline.window.end"))
    }

}
