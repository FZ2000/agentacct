import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Navigation preferences are separate from receipt/disposition storage.
/// Only task-scoped view state is persisted, never a reconstructed ledger.
enum WorkTimelinePreferences {
    static func key(_ taskID: String) -> String { "work.timeline.navigation.v1.\(taskID)" }
    static func load(taskID: String, defaults: UserDefaults = .standard) -> WorkTimelineNavigation {
        guard !SnapshotMode.enabled, let data = defaults.data(forKey: key(taskID)),
              let state = try? JSONDecoder().decode(WorkTimelineNavigation.self, from: data) else {
            return WorkTimelineNavigation()
        }
        return state
    }
    static func save(_ state: WorkTimelineNavigation, taskID: String, defaults: UserDefaults = .standard) {
        guard !SnapshotMode.enabled else { return }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key(taskID)) }
    }
}

private struct WorkCompactViewportKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workCompactViewport: Bool {
        get { self[WorkCompactViewportKey.self] }
        set { self[WorkCompactViewportKey.self] = newValue }
    }
}

private struct WorkTimelineSessionResponse {
    var id: String
    var detail: V1SessionDetail?
    var error: String?
}

struct WorkTimelineView: View {
    let receipt: Receipt
    var reviewSelectedRecord = false
    var onRevealInspector: (() -> Void)? = nil
    var onRevealRecords: (() -> Void)? = nil
    var onRevealHeading: (() -> Void)? = nil
    @Environment(DashboardStore.self) private var dashboard
    @Environment(AppSelection.self) private var appSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workCompactViewport) private var compactViewport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingOverview = false
    @State private var navigation = WorkTimelineNavigation()
    @State private var feed = WorkTimelineFeed()
    @State private var sessions: [String: V1SessionDetail] = [:]
    @State private var sessionErrors: [String: String] = [:]
    @State private var activeTaskID: String?
    @State private var loadingInitialSnapshot = false
    @State private var restoredPositionFromCurrentEvidence = false
    @State private var lastObserved: Date?
    @State private var scrollTarget: String?
    @State private var showingArrivals = false
    @State private var exportError: String?
    @FocusState private var focusedEvidence: String?
    @AccessibilityFocusState private var accessibleEvidence: String?
    @State private var requestedRowFocus: String?
    @State private var scrollRequest = 0
    @State private var stackedInspector = true
    @State private var viewIsVisible = false
    @State private var focusGeneration = 0
    @State private var viewport = WorkTimelineViewport()

    private var projection: WorkTimelineProjection {
        WorkTimelineProjection(receipt: receipt, sessions: sessions, errors: sessionErrors)
    }
    private var displayProjection: WorkTimelineProjection {
        SnapshotMode.enabled && !SnapshotMode.interactiveFixture
            ? WorkTimelineProjection(receipt: receipt, sessions: dashboard.preloadedSessions)
            : feed.visible
    }
    private var latestProjection: WorkTimelineProjection { SnapshotMode.enabled && !SnapshotMode.interactiveFixture ? displayProjection : feed.latest }
    private var loadedCount: Int {
        let available = SnapshotMode.enabled ? dashboard.preloadedSessions : sessions
        return (receipt.sessions ?? []).flatMap(\.members).filter { available[$0.id] != nil }.count
    }
    private var filtered: [WorkTimelineRecord] {
        displayProjection.records.filter { record in
            (!showingArrivals || feed.arrivalIDs.contains(record.id))
                && (navigation.view.query.isEmpty || record.searchableText.localizedCaseInsensitiveContains(navigation.view.query))
                && (navigation.view.file == nil || record.files.contains(navigation.view.file!))
                && (!navigation.view.failuresOnly || record.isCurrentFailure)
                && (navigation.view.interval?.contains(record) ?? true)
        }
    }
    private var selected: WorkTimelineRecord? { displayProjection.records.first { $0.id == navigation.view.selectedID } }
    private var interval: WorkTimelineInterval? { navigation.view.interval ?? displayProjection.interval }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            heading
            filters
            if !loadingInitialSnapshot, loadedCount < memberCount || !sessionErrors.isEmpty {
                Text(sessionErrors.isEmpty
                    ? "Activity incomplete · \(loadedCount) of \(memberCount) sessions loaded"
                    : "Session refresh failed · retained records may be outdated")
                    .workFont(.caption).foregroundStyle(Theme.amber)
            }
            if restoredPositionFromCurrentEvidence {
                Text("Position restored using current records. The earlier snapshot is no longer available.")
                    .workFont(.caption).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("work.timeline.restored-position")
            }
            if let file = navigation.view.file {
                HStack(alignment: .top) {
                    Text("Exact file reference: \(file)").workFont(.caption).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(navigation.view.previousFileFilters == nil ? "Clear file" : "Back to previous filters") {
                        hold(); navigation.leaveFile()
                    }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                }
            }
            if showingOverview {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Text("Time range").workFont(.captionSemibold)
                        Spacer()
                        Button("Done") { showingOverview = false; navigation.view.overviewExpanded = false }
                            .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                    }
                    overview
                    rangeControls
                }
                .accessibilityIdentifier("work.timeline.time-range")
            }
            if showingArrivals {
                let arrivals = feed.arrivalIDs.count - feed.removedArrivalCount
                Text("\(arrivals) new or changed \(arrivals == 1 ? "record" : "records")")
                    .workFont(.caption).foregroundStyle(Theme.muted)
                if feed.removedArrivalCount > 0 {
                    Text("\(feed.removedArrivalCount) earlier \(feed.removedArrivalCount == 1 ? "record is" : "records are") unavailable in this snapshot.")
                        .workFont(.caption).foregroundStyle(Theme.amber)
                }
            }
            evidenceAndInspector
            if let exportError { Text(exportError).workFont(.caption).foregroundStyle(Theme.coral) }
            DisclosureGroup("Recording details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(displayProjection.records.count) records from \(loadedCount) of \(memberCount) loaded sessions. Search covers only loaded activity.")
                    Text(dashboard.isOfflineSnapshot ? "Saved copies only. No recorder requests or changes are made from this view." : "Snapshots refresh every 3 seconds while this view is open. Intermediate changes between snapshots may not be available.")
                    Text(lastObserved.map { "Last successful session snapshot: \(Self.dateText($0.timeIntervalSince1970))." } ?? "No live session snapshot received in this view.")
                    ForEach(latestProjection.lanes) { lane in
                        Text("\(lane.title): \(lane.availability)")
                    }
                    ForEach(latestProjection.notices, id: \.self) { Text($0) }
                    Text("Recorded section spans end at their latest update. Check markers are points. Neither shape implies measured execution time.")
                }
                .workFont(.caption).foregroundStyle(Theme.muted).padding(.top, 6)
            }
            .workFont(.caption)
        }
        .workFont(.body)
        .padding(Space.m)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.cardLine))
        .task(id: loadKey) { await loadTask() }
        .onChange(of: projection) { _, value in
            guard activeTaskID == receipt.taskId else { return }
            receive(value)
        }
        .onChange(of: dashboard.nativeReviewRevision) { _, _ in
            guard SnapshotMode.enabled, SnapshotMode.interactiveFixture else { return }
            sessions = dashboard.preloadedSessions
            receive(projection)
        }
        .onChange(of: navigation) { _, value in
            guard let activeTaskID else { return }
            WorkTimelinePreferences.save(value, taskID: activeTaskID)
        }
        .onChange(of: focusedEvidence) { _, id in
            guard let id, id != "timeline-heading", id != "records" else { return }
            let recordID = id == "inspector" ? navigation.view.selectedID : id
            appSelection.workReturnFocus.remember(taskID: receipt.taskId, recordID: recordID)
        }
        .onAppear { viewIsVisible = true }
        .onDisappear { viewIsVisible = false; focusGeneration += 1; saveMemory() }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { stackedInspector = geometry.size.width - Space.m * 2 < 1072 }
                    .onChange(of: geometry.size.width) { _, width in stackedInspector = width - Space.m * 2 < 1072 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.timeline")
    }

    /// The record column keeps one identity as the optional inspector opens or
    /// the window changes width. An unused inspector reserves no space.
    private var evidenceAndInspector: some View {
        let layout = stackedInspector
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.m))
        return layout {
            evidenceColumn.frame(maxWidth: .infinity)
            if navigation.view.selectedID != nil {
                if stackedInspector {
                    inspector
                } else {
                    ScrollView { inspector }.frame(width: 320, height: 550)
                }
            }
        }
    }

    private var overview: some View {
        WorkTimelineOverview(projection: displayProjection, window: interval, selectedID: navigation.view.selectedID,
            onRange: { hold(); navigation.view.interval = $0 },
            onSelect: { record in inspect(record, focusInspector: false); focusSelectedRange(); returnToRecord(record) })
    }

    private var evidenceColumn: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            recordsSurface
                .id("work.timeline.records")
                .animation(reduceMotion || !navigation.following ? nil : .easeInOut(duration: 0.22), value: displayProjection.records)
        }
    }

    private var memberCount: Int { Set((receipt.sessions ?? []).flatMap(\.members).map(\.id)).count }

    private var loadKey: String {
        receipt.taskId + "|" + (receipt.sessions ?? []).flatMap(\.members).map(\.id).sorted().joined(separator: "|")
    }

    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { headingLabel; Spacer(minLength: 0); liveControls; activityMenu }
            VStack(alignment: .leading, spacing: 8) {
                headingLabel
                HStack(spacing: 8) { liveControls; Spacer(); activityMenu }
            }
        }
    }
    private var headingLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
            Text("Activity").workFont(.titleCard)
                .id("work.timeline.heading")
                .focusable().focused($focusedEvidence, equals: "timeline-heading")
                .accessibilityFocused($accessibleEvidence, equals: "timeline-heading")
                .accessibilityAddTraits(.isHeader)
                ContextHelp(title: "About activity",
                    message: "Bars show a section's recorded start through its latest update; dots show checks. These are recorded timestamps, not measured execution duration. Select a record to inspect its source, scope and files. Live snapshots refresh every 3 seconds; changes between snapshots may not be available.",
                    identifier: "work.timeline.help")
            }
            HStack(spacing: 5) {
                if loadingInitialSnapshot && !reduceMotion {
                    ProgressView().controlSize(.mini).accessibilityLabel("Loading session evidence")
                }
                if dashboard.isOfflineSnapshot {
                    Text("Saved copy · offline").workFont(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var activityMenu: some View {
        Menu {
            Button(showingOverview ? "Hide time range" : "Adjust time range…") {
                hold(); showingOverview.toggle(); navigation.view.overviewExpanded = showingOverview
            }.buttonStyle(QuietButtonStyle())
            Divider()
            Button("Export visible records…", action: exportReview)
                .disabled(filtered.isEmpty)
                .buttonStyle(QuietButtonStyle())
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
        .fixedSize()
        .accessibilityLabel("Activity actions")
        .accessibilityIdentifier("work.timeline.actions")
        .help("Activity actions")
    }

    private func exportReview() {
        hold()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "work-review.txt"
        panel.title = "Export displayed work evidence"
        panel.message = "\(filtered.count) visible \(filtered.count == 1 ? "record" : "records") with source identities and recording limitations."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let content = WorkTimelineExport.text(taskID: receipt.taskId, title: receipt.title,
                records: filtered, projection: displayProjection, following: navigation.following,
                query: navigation.view.query, file: navigation.view.file, generatedAt: Date(),
                snapshotAt: lastObserved,
                failuresOnly: navigation.view.failuresOnly, interval: interval,
                offlineReceiptAt: dashboard.receiptSavedAt,
                outcome: receipt.axes.decisionStatus.key,
                handoff: receipt.axes.handoff.map { "\($0.handedOff == true ? "Handed off" : "Not the current handoff frontier") · \($0.statement ?? "No handoff statement supplied")" })
            try content.write(to: destination, atomically: true, encoding: .utf8)
            exportError = nil
        } catch { exportError = "Could not export this review: \(error.localizedDescription)" }
    }

    @ViewBuilder private var liveControls: some View {
        let pendingCount = feed.pendingIDs.count
        if !dashboard.isOfflineSnapshot {
        Button {
            cancelDeferredFocus()
            if navigation.following { hold() } else {
                navigation.following = true
                showingArrivals = false
                feed.reveal()
                navigation.view.interval = displayProjection.interval
                scrollTarget = displayProjection.newestRecord?.id
            }
        } label: {
            Label(navigation.following ? "Following live" : "Resume live", systemImage: navigation.following ? "pause.circle" : "play.circle")
        }
        .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
        .accessibilityLabel(navigation.following ? "Pause live updates" : "Resume live updates")
        .disabled(dashboard.isOfflineSnapshot)
        .help("Pause to keep this history still. Resume reveals the latest snapshot and moves to its newest record; search and file filters stay in place.")
        .accessibilityIdentifier("work.timeline.follow")
        Button("\(pendingCount) \(pendingCount == 1 ? "update" : "updates") · Review") {
            if navigation.history == nil { navigation.view.scrollOffsets = viewport.capture() }
            navigation.beginArrivals()
            feed.reviewArrivals()
            navigation.view.interval = displayProjection.interval
            showingArrivals = true
        }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
        .disabled(pendingCount == 0)
        // Keep the control's space so arrivals never push held history down.
        // Empty counts do not need to compete with the live state label.
        .opacity(pendingCount == 0 ? 0 : 1)
        .accessibilityHidden(pendingCount == 0)
        .accessibilityIdentifier("work.timeline.arrivals")
        if navigation.history != nil {
            Button("Back to history") {
                navigation.returnToHistory()
                feed.restoreHistory()
                showingArrivals = false
                showingOverview = navigation.view.overviewExpanded ?? false
                restoreHistoryPosition()
            }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
            .accessibilityIdentifier("work.timeline.history")
        }
        }
    }

    private var filters: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(spacing: Space.m))
        return VStack(alignment: .leading, spacing: 8) {
            layout {
                recordSearch
                viewModeSelector
            }
            let failureCount = displayProjection.records.filter(\.isCurrentFailure).count
            if failureCount > 0 || navigation.view.failuresOnly || hasActiveFilters {
                layout {
                    if failureCount > 0 || navigation.view.failuresOnly {
                        Button(navigation.view.failuresOnly ? "Show all records" : "\(failureCount) failed \(failureCount == 1 ? "record" : "records")") {
                            hold(); navigation.view.failuresOnly.toggle()
                        }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                        .accessibilityIdentifier("work.timeline.failures")
                        .help("Current failures in loaded records; one check may appear in more than one source.")
                    }
                    if hasActiveFilters {
                        Text("\(filtered.count) of \(displayProjection.records.count) loaded records")
                            .workFont(.caption).foregroundStyle(Theme.muted)
                        Button("Clear filters") { clearFilters() }
                            .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                            .accessibilityIdentifier("work.timeline.clear-filters")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var hasActiveFilters: Bool {
        !navigation.view.query.isEmpty || navigation.view.file != nil
            || navigation.view.failuresOnly
            || (navigation.view.interval != nil && navigation.view.interval != displayProjection.interval)
    }

    private func clearFilters() {
        hold()
        navigation.view.query = ""
        navigation.view.file = nil
        navigation.view.previousFileFilters = nil
        navigation.view.failuresOnly = false
        navigation.view.interval = displayProjection.interval
    }

    private var recordSearch: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            TextField("Search activity", text: Binding(
                get: { navigation.view.query },
                set: { hold(); navigation.view.query = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .workFont(.body)
            .accessibilityLabel("Search loaded activity, sessions and files")
            .accessibilityIdentifier("work.timeline.search")
        }
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private var viewModeSelector: some View {
        HStack(spacing: Space.s) {
            ForEach(["timeline", "list"], id: \.self) { mode in
                Button(mode == "timeline" ? "Timeline" : "List") {
                    guard navigation.view.mode != mode else { return }
                    hold()
                    navigation.view.mode = mode
                }
                .buttonStyle(NativeSetupActionStyle(prominent: navigation.view.mode == mode))
                .accessibilityLabel(mode == "timeline" ? "Timeline view" : "List view")
                .accessibilityAddTraits(navigation.view.mode == mode ? .isSelected : [])
                .accessibilityIdentifier("work.timeline.mode.\(mode)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recorded work view")
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { shiftRange(-0.5) } label: { Label("Earlier", systemImage: "chevron.left") }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                Button { shiftRange(0.5) } label: { Label("Later", systemImage: "chevron.right") }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                Button("−") { zoomRange(2) }.buttonStyle(QuietButtonStyle(horizontalPadding: 8)).accessibilityLabel("Zoom out")
                Button("+") { zoomRange(0.5) }.buttonStyle(QuietButtonStyle(horizontalPadding: 8)).accessibilityLabel("Zoom in")
                Button("Fit") { hold(); navigation.view.interval = displayProjection.interval }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                Button("Focus selected") { focusSelectedRange() }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                    .disabled(selected?.start == nil)
                    .opacity(selected?.start == nil ? 0 : 1)
                    .accessibilityHidden(selected?.start == nil)
                    .help("Show the selected record's recorded span with at least one minute of context on each side")
                    .accessibilityIdentifier("work.timeline.focus-range")
                Spacer(minLength: 0)
            }.disabled(interval == nil)
            if let interval {
                Text("\(Self.dateText(interval.lower)) → \(Self.dateText(interval.upper))")
                    .workFont(.dataSmall).foregroundStyle(Theme.muted).textSelection(.enabled)
            } else {
                Text("No dated records; undated evidence is listed below.").workFont(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private var recordsSurface: some View {
        if SnapshotMode.enabled && !SnapshotMode.interactiveFixture {
            GeometryReader { geometry in
                recordsContent.frame(width: max(geometry.size.width, 760), alignment: .topLeading)
            }
            .frame(height: 390).clipped().background(Theme.canvas)
        } else {
            GeometryReader { geometry in
                let contentWidth = max(geometry.size.width, navigation.view.mode == "timeline" ? 760 : 460)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        if navigation.view.mode == "timeline", interval != nil { timeAxis }
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                recordsContent
                                    .frame(width: contentWidth, alignment: .topLeading)
                                    .background(WorkTimelineScrollObserver(viewport: viewport) { hold() })
                            }
                            .frame(height: navigation.view.mode == "timeline" && interval != nil ? 350 : 390)
                            .focusable().focused($focusedEvidence, equals: "records")
                            .accessibilityFocused($accessibleEvidence, equals: "records")
                            .accessibilityLabel("Recorded evidence")
                            .task(id: "\(scrollTarget ?? ""):\(scrollRequest)") {
                                guard let id = scrollTarget else { return }
                                // The target can arrive in the same transaction
                                // as a new lazy-list body. Wait for that layout.
                                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                                guard !Task.isCancelled, scrollTarget == id else { return }
                                proxy.scrollTo(id, anchor: .center)
                                if requestedRowFocus == id {
                                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                                    guard !Task.isCancelled, requestedRowFocus == id else { return }
                                    focusedEvidence = id; accessibleEvidence = id; requestedRowFocus = nil
                                }
                            }
                            .onMoveCommand { direction in moveSelection(direction) }
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                }
            }
            .frame(height: 390)
            .background(Theme.canvas)
            .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.hairline))
        }
    }

    @ViewBuilder private var timeAxis: some View {
        if let interval {
            HStack {
                Text("Recorded time").frame(width: 285, alignment: .leading)
                HStack {
                    Text(WorkTimelineTimeAxis.label(interval.lower, range: interval))
                    Spacer()
                    Text(WorkTimelineTimeAxis.label((interval.lower + interval.upper) / 2, range: interval))
                    Spacer()
                    Text(WorkTimelineTimeAxis.label(interval.upper, range: interval))
                }
            }
            .workFont(.dataSmall).foregroundStyle(Theme.muted).padding(10)
            .frame(height: 40).background(Theme.canvas)
        }
    }

    private var recordsContent: some View {
        ScrollContentStack(alignment: .leading, spacing: 0) {
            if filtered.isEmpty {
                Text(displayProjection.records.isEmpty ? "No activity recorded yet." : "No loaded records match these filters.")
                    .workFont(.body).foregroundStyle(Theme.muted).padding(Space.l)
            } else if navigation.view.mode == "list" {
                ForEach(filtered) { record in recordRow(record, showRail: false) }
            } else {
                timelineRows
            }
        }
        .frame(minWidth: navigation.view.mode == "timeline" ? 760 : 460, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var timelineRows: some View {
        if SnapshotMode.enabled && !SnapshotMode.interactiveFixture { timeAxis }
        let datedByLane = Dictionary(grouping: filtered.filter { $0.start != nil }, by: \.laneID)
        ForEach(displayProjection.lanes) { lane in
            let records = datedByLane[lane.id] ?? []
            if !records.isEmpty {
                HStack(spacing: 6) {
                    Text(lane.title).workFont(.rowLabel)
                    ContextHelp(title: "Session details", message: "\(lane.title)\n\(lane.lineage)\n\(lane.id)\n\(lane.availability)")
                    if lane.id.hasPrefix("task:") {
                        Text("Session unknown").workFont(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.tintNeutral)
                ForEach(records) { record in recordRow(record, showRail: true) }
            }
        }
        let undated = filtered.filter { $0.start == nil }
        if !undated.isEmpty {
            Text("Time unavailable")
                .workFont(.rowLabel).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.tintNeutral)
            ForEach(undated) { record in recordRow(record, showRail: false) }
        }
    }

    private func recordRow(_ record: WorkTimelineRecord, showRail: Bool) -> some View {
        Button { inspect(record) } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol(record)).foregroundStyle(color(record)).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).workFont(.rowLabel).lineLimit(2)
                    Text("\(record.resultLabel)\(record.superseded ? " · Superseded" : "")")
                        .workFont(.caption).foregroundStyle(color(record))
                    Text(showRail ? record.source : "\(record.laneTitle) · \(record.source)")
                        .workFont(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                }
                .frame(width: showRail ? 245 : nil, alignment: .leading)
                if showRail, let interval, let start = record.start {
                    rail(record, start: start, interval: interval)
                } else {
                    Spacer(minLength: 10)
                    Text(record.start.map(Self.shortTime) ?? "Undated").workFont(.dataSmall).foregroundStyle(Theme.muted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(navigation.view.selectedID == record.id ? Theme.selected : Theme.card)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle(focusInset: 2))
        .help("Inspect this record's source, scope, identity and files")
        .id(record.id)
        .focusable()
        .focused($focusedEvidence, equals: record.id)
        .accessibilityFocused($accessibleEvidence, equals: record.id)
        .accessibilityIdentifier("work.timeline.record.\(record.id)")
        .accessibilityLabel("\(record.title), \(record.resultLabel), \(record.laneTitle), \(record.source), \(record.start.map(Self.dateText) ?? "time unavailable")\(record.superseded ? ", superseded" : "")")
        .accessibilityHint("Open record details")
    }

    private func rail(_ record: WorkTimelineRecord, start: Double, interval: WorkTimelineInterval) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 12, 1)
            let x = interval.fraction(start) * width
            let endX = interval.fraction(record.end ?? start) * width
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if record.isDuration {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.3))
                        .frame(width: max(endX - x, 3), height: 10).offset(x: x)
                    Rectangle().fill(Theme.accent).frame(width: 2, height: 14).offset(x: endX)
                }
                Circle().fill(color(record)).frame(width: 8, height: 8).offset(x: x)
            }
            .frame(height: geometry.size.height)
        }
        .frame(minWidth: 300).frame(height: 36)
        .accessibilityHidden(true)
    }

    private func evidenceIdentity(_ record: WorkTimelineRecord) -> String {
        record.laneID.hasPrefix("task:")
            ? "Task evidence identity: \(record.laneID) · session attribution unavailable"
            : "Session identity: \(record.laneID)"
    }

    @ViewBuilder private var inspector: some View {
        if let record = selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text(record.title).workFont(.titleCard)
                        .fixedSize(horizontal: false, vertical: true)
                        .focusable().focused($focusedEvidence, equals: "inspector")
                        .accessibilityFocused($accessibleEvidence, equals: "inspector")
                        .accessibilityAddTraits(.isHeader)
                        .onKeyPress(.escape) { dismissInspector(record); return .handled }
                    Spacer(minLength: 0)
                    Button { dismissInspector(record) } label: { Image(systemName: "xmark") }
                        .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                        .accessibilityLabel("Close record details")
                        .accessibilityIdentifier("work.timeline.inspector.close")
                        .help("Close record details")
                }
                Text("\(record.resultLabel) · \(record.source)\(record.superseded ? " · Superseded" : "")")
                    .workFont(.body).foregroundStyle(color(record))
                Text(record.start.map(Self.dateText) ?? "Source time unavailable")
                    .workFont(.caption).foregroundStyle(Theme.muted)
                if let summary = record.summary, summary != record.title {
                    Text(summary).workFont(.body).textSelection(.enabled)
                }
                if let warning = record.timeWarning { Text(warning).workFont(.caption).foregroundStyle(Theme.amber) }
                if let disposition = record.disposition {
                    Text("Human disposition: \(disposition). The recorded check result is unchanged.").workFont(.caption)
                }
                if let resolution = record.resolutionDescription { Text(resolution).workFont(.caption).textSelection(.enabled) }
                if let code = record.exitCode, code != 0 { Text("Exit code: \(code)").workFont(.caption) }
                if let note = record.identityNote { Text(note).workFont(.caption).foregroundStyle(Theme.amber) }
                if !filtered.contains(where: { $0.id == record.id }) {
                    Text("Outside the current filters").workFont(.caption).foregroundStyle(Theme.amber)
                    Button("Show this record") { clearFilters(); returnToRecord(record) }
                        .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                }
                let associatedChecks = displayProjection.records.filter { $0.sectionRecordID == record.id }
                if !associatedChecks.isEmpty {
                    DisclosureGroup("Checks · \(associatedChecks.count)") {
                        ForEach(associatedChecks) { check in
                            Button("\(check.title) · \(check.resultLabel)\(check.superseded ? " · Superseded" : "") · \(check.source)") { inspect(check) }
                                .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.workFont(.caption)
                }
                if let supersededBy = record.supersededBy {
                    if displayProjection.records.contains(where: { $0.eventID == supersededBy }) {
                        Button("View later result") { inspectEvent(supersededBy) }
                            .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                    } else {
                        Text("The later result is not in loaded activity.").workFont(.caption).foregroundStyle(Theme.muted)
                    }
                } else if record.superseded {
                    Text("The source marks this check superseded; a target event is not supplied.").workFont(.caption)
                }
                if let sectionID = record.sectionRecordID {
                    Button("View work section") {
                        if let section = displayProjection.records.first(where: { $0.id == sectionID }) { inspect(section) }
                    }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                }
                if !record.files.isEmpty {
                    DisclosureGroup("Files · \(record.files.count)") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(record.files, id: \.self) { file in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(file).workFont(.caption).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button { hold(); navigation.showFile(file) } label: {
                                        Image(systemName: "line.3.horizontal.decrease.circle")
                                    }
                                    .buttonStyle(QuietButtonStyle(horizontalPadding: 6))
                                    .help("Find loaded activity referencing this file")
                                    .accessibilityLabel("Find loaded activity referencing \(file)")
                                }
                            }
                            ContextHelp(title: "About file references",
                                message: "These paths are recorded associations. File contents and diffs are not captured here. Filtering by a file temporarily replaces the other filters; Back to previous filters restores them.")
                        }.padding(.top, 6)
                    }.workFont(.caption)
                }
                if !record.artifactDescriptions.isEmpty {
                    DisclosureGroup("Artifacts") {
                        ForEach(record.artifactDescriptions, id: \.self) { Text($0).textSelection(.enabled) }
                    }.workFont(.caption)
                }
                DisclosureGroup("Record details") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scope: \(record.scope ?? "unavailable")")
                        if let exitCode = record.exitCode { Text("Recorded exit code: \(exitCode)") }
                        Text(record.timeNote)
                        Text("Session: \(record.laneTitle)")
                        Text(evidenceIdentity(record))
                        Text(record.lineage)
                        Text("Event: \(record.eventID ?? "not supplied")")
                        if let start = record.start { Text("Source time: \(WorkTimelineTimeAxis.preciseLabel(start))") }
                        if let end = record.end { Text("Latest update: \(WorkTimelineTimeAxis.preciseLabel(end))") }
                        if let supersededBy = record.supersededBy { Text("Superseded by event: \(supersededBy)") }
                        if record.commandRedacted { Text("Command text was deliberately not captured.") }
                    }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 6)
                }
                .workFont(.caption)
                .accessibilityIdentifier("work.timeline.inspector.identity")
            }
            .id(record.id)
            .padding(Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Metrics.radius))
            .id("work.timeline.inspector")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work.timeline.inspector")
        } else if navigation.view.selectedID != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("This record is unavailable in the current snapshot.").workFont(.caption).foregroundStyle(Theme.muted)
                Button("Dismiss") { navigation.view.selectedID = nil }
                    .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
            }
        }
    }

    private func dismissInspector(_ record: WorkTimelineRecord) {
        navigation.view.selectedID = nil
        returnToRecord(record)
    }

    private func inspect(_ record: WorkTimelineRecord, focusInspector: Bool = true) {
        hold()
        navigation.view.selectedID = record.id
        navigation.view.anchorID = record.id
        appSelection.workReturnFocus.remember(taskID: receipt.taskId, recordID: record.id)
        if focusInspector {
            let generation = focusGeneration
            Task { @MainActor in
                await Task.yield()
                guard viewIsVisible, navigation.view.selectedID == record.id, generation == focusGeneration else { return }
                if stackedInspector { onRevealInspector?() }
                try? await Task.sleep(for: .milliseconds(180))
                guard viewIsVisible, navigation.view.selectedID == record.id, generation == focusGeneration else { return }
                focusedEvidence = "inspector"; accessibleEvidence = "inspector"
            }
        }
    }
    private func returnToRecord(_ record: WorkTimelineRecord) {
        cancelDeferredFocus()
        if stackedInspector { onRevealRecords?() }
        scrollTarget = record.id
        requestedRowFocus = record.id
        scrollRequest += 1
    }
    private func restoreHistoryPosition() {
        cancelDeferredFocus()
        scrollTarget = nil
        let generation = focusGeneration
        let taskID = receipt.taskId
        let offsets = navigation.view.scrollOffsets
        Task { @MainActor in
            // Wait for the original rows and outer layout to return before
            // restoring geometry. A newer user interaction cancels this work.
            try? await Task.sleep(for: .milliseconds(180))
            guard viewIsVisible, activeTaskID == taskID, generation == focusGeneration else { return }
            focusedEvidence = "records"; accessibleEvidence = "records"
            await Task.yield()
            guard generation == focusGeneration else { return }
            if let offsets, viewport.restore(offsets) { return }
            if let id = navigation.view.anchorID ?? navigation.view.selectedID,
               let record = filtered.first(where: { $0.id == id }) {
                returnToRecord(record)
            } else {
                onRevealHeading?()
                focusedEvidence = "timeline-heading"; accessibleEvidence = "timeline-heading"
            }
        }
    }
    private func restoreReturnFocusIfReady() {
        guard !loadingInitialSnapshot,
              let target = appSelection.workReturnFocus.consume(taskID: receipt.taskId, visibleRecordIDs: Set(filtered.map(\.id))) else { return }
        switch target {
        case .record(let id):
            hold()
            navigation.view.selectedID = id
            navigation.view.anchorID = id
            if stackedInspector { onRevealRecords?() }
            scrollTarget = id
            requestedRowFocus = id
            scrollRequest += 1
        case .heading:
            let taskID = receipt.taskId
            let generation = focusGeneration
            onRevealHeading?()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard viewIsVisible, activeTaskID == taskID, appSelection.taskId == taskID, generation == focusGeneration else { return }
                focusedEvidence = "timeline-heading"; accessibleEvidence = "timeline-heading"
            }
        }
    }

    private func focusSelectedRange() {
        guard let selected, let range = WorkTimelineRangeNavigation.focused(on: selected) else { return }
        hold()
        navigation.view.interval = range
        scrollTarget = selected.id
        scrollRequest += 1
    }
    private func inspectEvent(_ eventID: String) {
        if let record = displayProjection.records.first(where: { $0.eventID == eventID }) { inspect(record) }
    }
    private func cancelDeferredFocus() {
        appSelection.workReturnFocus.cancel()
        focusGeneration += 1
        requestedRowFocus = nil
    }
    private func hold() {
        // New interaction wins over both pending and already scheduled focus.
        cancelDeferredFocus()
        loadingInitialSnapshot = false
        navigation.following = false
    }
    private func moveSelection(_ direction: MoveCommandDirection) {
        let rows = displayProjection.displayedOrder(filtered, mode: navigation.view.mode)
        guard direction == .up || direction == .down, !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == navigation.view.selectedID } ?? (direction == .down ? -1 : rows.count)
        let next = min(max(index + (direction == .down ? 1 : -1), 0), rows.count - 1)
        inspect(rows[next], focusInspector: false); returnToRecord(rows[next])
    }
    private func shiftRange(_ amount: Double) {
        guard let current = interval else { return }
        hold()
        navigation.view.interval = WorkTimelineInterval(lower: current.lower + current.span * amount, upper: current.upper + current.span * amount)
    }
    private func zoomRange(_ scale: Double) {
        guard let current = interval else { return }
        hold()
        let selectedTime = selected?.start
        let center = selectedTime.flatMap { current.lower...current.upper ~= $0 ? $0 : nil } ?? (current.lower + current.upper) / 2
        let half = max(current.span * scale / 2, 0.5)
        navigation.view.interval = WorkTimelineInterval(lower: center - half, upper: center + half)
    }
    private func receive(_ projection: WorkTimelineProjection) {
        let previousLatest = displayProjection.newestRecord?.id
        feed.ingest(projection, following: navigation.following || loadingInitialSnapshot)
        if navigation.following {
            navigation.view.interval = displayProjection.interval
            let latestID = displayProjection.newestRecord?.id
            if latestID != previousLatest { scrollTarget = latestID }
        }
    }
    private func saveMemory() {
        guard let activeTaskID, !dashboard.isOfflineSnapshot, !SnapshotMode.enabled else { return }
        WorkTimelineMemory.cache.save(.init(feed: feed, sessions: sessions), for: activeTaskID)
        WorkTimelinePreferences.save(navigation, taskID: activeTaskID)
    }

    @MainActor private func loadTask() async {
        let taskID = receipt.taskId
        saveMemory()
        activeTaskID = taskID
        navigation = WorkTimelinePreferences.load(taskID: taskID)
        showingOverview = navigation.view.overviewExpanded ?? false
        let cached = dashboard.isOfflineSnapshot || SnapshotMode.enabled ? nil : WorkTimelineMemory.cache.load(taskID)
        feed = cached?.feed ?? WorkTimelineFeed()
        sessions = cached?.sessions ?? [:]
        restoredPositionFromCurrentEvidence = cached == nil && navigation.restorePositionWithoutSnapshot()
        if dashboard.isOfflineSnapshot { navigation.following = false }
        loadingInitialSnapshot = cached == nil && !SnapshotMode.enabled && !dashboard.isOfflineSnapshot
        sessionErrors = [:]
        lastObserved = nil
        showingArrivals = navigation.history != nil
        scrollTarget = navigation.view.anchorID
        for member in (receipt.sessions ?? []).flatMap(\.members) {
            if let preloaded = dashboard.preloadedSessions[member.id] { sessions[member.id] = preloaded }
        }
        receive(projection)
        if SnapshotMode.enabled && reviewSelectedRecord {
            navigation.following = false
            navigation.view.selectedID = displayProjection.records.first?.id
        }
        restoreReturnFocusIfReady()
        guard !SnapshotMode.enabled, !dashboard.isOfflineSnapshot else { return }
        while !Task.isCancelled && activeTaskID == taskID {
            var seen = Set<String>()
            let members = (receipt.sessions ?? []).flatMap(\.members).filter { seen.insert($0.id).inserted }
            // Four concurrent requests bound daemon pressure for large tasks.
            // A cancelled SwiftUI task cancels every child request as well.
            for offset in stride(from: 0, to: members.count, by: 4) {
                await withTaskGroup(of: WorkTimelineSessionResponse.self) { group in
                    for member in members[offset..<min(offset + 4, members.count)] {
                        group.addTask {
                            do {
                                let detail = try await dashboard.loadSession(client: member.client, sessionId: member.clientSessionId)
                                return WorkTimelineSessionResponse(id: member.id, detail: detail, error: nil)
                            } catch {
                                return WorkTimelineSessionResponse(id: member.id, detail: nil, error: error.localizedDescription)
                            }
                        }
                    }
                    for await response in group {
                        guard !Task.isCancelled, activeTaskID == taskID else { group.cancelAll(); return }
                        if let detail = response.detail {
                            sessions[response.id] = detail
                            sessionErrors.removeValue(forKey: response.id)
                            lastObserved = Date()
                        } else {
                            sessionErrors[response.id] = response.error
                        }
                    }
                }
                guard !Task.isCancelled, activeTaskID == taskID else { return }
            }
            // Ingest the final initial batch before closing baseline hydration;
            // SwiftUI may coalesce the session state changes until this await.
            receive(projection)
            loadingInitialSnapshot = false
            // Missing/filtered evidence focuses the heading, never another row.
            restoreReturnFocusIfReady()
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    private func color(_ record: WorkTimelineRecord) -> Color {
        if record.superseded || record.disposition != nil { return Theme.muted }
        if record.isCurrentFailure { return Theme.coral }
        return record.kind == .step ? Theme.accent : Theme.ink
    }
    private func symbol(_ record: WorkTimelineRecord) -> String {
        if record.superseded { return "clock.arrow.circlepath" }
        if record.kind == .step { return "text.alignleft" }
        switch record.result {
        case "failed", "error": return "xmark.circle"
        case "passed": return "checkmark.circle"
        case "skipped": return "forward.end"
        default: return "questionmark.circle"
        }
    }
    private static func dateText(_ time: Double) -> String {
        Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .standard)
    }
    private static func shortTime(_ time: Double) -> String {
        Date(timeIntervalSince1970: time).formatted(date: .omitted, time: .standard)
    }
}

/// A scoped event observer holds the timeline when native scrolling begins.
/// It returns the event unchanged and never captures events from another pane.
private struct WorkTimelineScrollObserver: NSViewRepresentable {
    var viewport: WorkTimelineViewport
    var onScroll: () -> Void
    func makeNSView(context: Context) -> ScrollObserverView {
        let view = ScrollObserverView()
        view.onScroll = onScroll
        viewport.anchor = view
        return view
    }
    func updateNSView(_ nsView: ScrollObserverView, context: Context) {
        nsView.onScroll = onScroll
        viewport.anchor = nsView
    }
    static func dismantleNSView(_ nsView: ScrollObserverView, coordinator: ()) { nsView.stop() }

    final class ScrollObserverView: NSView {
        var onScroll: (() -> Void)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window == self.window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onScroll?()
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
