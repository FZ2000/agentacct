import SwiftUI

// Sources — what feeds the evidence store, exactly as the ingestion-health
// snapshot reports it: per-source import state and recency, the continuous-
// sync watcher, actionable issues, the verifier shelf (named not-connected
// states), and the scope-transparency card. Everything on this page is a
// live-connection fact from /v1/ingestion — nothing is a capability claim.

// MARK: - /v1/ingestion wire model (additive; every field optional)

struct V1IngestionPayload: Decodable {
    let schema: String
    let ingestion: V1IngestionSnapshot
}

struct V1IngestionSnapshot: Decodable {
    let state: String?
    let lastSuccessAt: Double?
    let sources: [V1IngestionSource]?
    let watcher: V1IngestionWatcher?
    let issues: [V1IngestionIssue]?
    /// Reducer-owned display copy for `state` (`ingestion_state_copy`): the
    /// title and one fact sentence. A state key is never rendered as a title.
    var stateTitle: String?
    var stateDetail: String?
    /// The reducer's rail-length twin of `stateDetail`, leading with the named
    /// absence, for a one-line signal row the sentence does not fit (K69).
    var stateDetailCompact: String?

    enum CodingKeys: String, CodingKey {
        case state, sources, watcher, issues
        case lastSuccessAt = "last_success_at"
        case stateTitle = "state_title"
        case stateDetail = "state_detail"
        case stateDetailCompact = "state_detail_compact"
    }
}

struct V1IngestionSource: Decodable, Identifiable {
    let source: String
    let state: String?
    let scope: String?
    let lastSuccessAt: Double?
    let lastFailureAt: Double?
    let discovered: Int?
    let parsed: Int?
    let skipped: Int?
    let errorCount: Int?
    /// Reducer-owned display copy for this source (`source_state_copy`):
    /// `Reporting` / `Watching · no data yet` / `Idle` / `Degraded` / … and one
    /// fact sentence. Swift never titles a state key itself.
    var stateTitle: String? = nil
    var stateDetail: String? = nil

    var id: String { source }

    enum CodingKeys: String, CodingKey {
        case source, state, scope, discovered, parsed, skipped
        case stateTitle = "state_title"
        case stateDetail = "state_detail"
        case lastSuccessAt = "last_success_at"
        case lastFailureAt = "last_failure_at"
        case errorCount = "error_count"
    }
}

struct V1IngestionWatcher: Decodable {
    let state: String?
    let intervalSeconds: Double?
    let heartbeatAt: Double?
    /// Reducer-owned display copy for the watcher (`watcher_state_copy`).
    var stateTitle: String? = nil
    var stateDetail: String? = nil

    enum CodingKeys: String, CodingKey {
        case state
        case intervalSeconds = "interval_seconds"
        case heartbeatAt = "heartbeat_at"
        case stateTitle = "state_title"
        case stateDetail = "state_detail"
    }
}

struct V1IngestionIssue: Decodable, Identifiable {
    let code: String?
    let source: String?
    let action: String?

    var id: String { "\(code ?? "?")-\(source ?? "*")" }
}

/// Only this backend code is a store-wide cause projected onto each source.
/// All other diagnostics, including watcher staleness, remain independent.
struct SourceIssueGroup: Identifiable {
    static let globalReconciliationCode = "evidence_refreshable_usage_failed"
    let id: String
    private(set) var issues: [V1IngestionIssue]

    var isGlobalReconciliation: Bool { issues.first?.code == Self.globalReconciliationCode }
    var affectedSources: [String] { Array(Set(issues.compactMap(\.source))).sorted() }

    static func group(_ issues: [V1IngestionIssue]) -> [Self] {
        var result: [Self] = []
        var globalIndex: Int?
        for (index, issue) in issues.enumerated() {
            if issue.code == globalReconciliationCode {
                if let globalIndex {
                    result[globalIndex].issues.append(issue)
                } else {
                    globalIndex = result.count
                    result.append(Self(id: "global:\(globalReconciliationCode)", issues: [issue]))
                }
            } else {
                // Repeated source/code pairs can carry different diagnostics.
                // Retain every original row instead of inferring a common cause.
                result.append(Self(id: "issue:\(index):\(issue.id)", issues: [issue]))
            }
        }
        return result
    }
}

struct SourceHealthPresentation {
    let refreshError: String?
    var isRetained: Bool { refreshError != nil }

    func watcherIsCurrentlyRunning(_ watcher: V1IngestionWatcher?) -> Bool {
        !isRetained && watcher?.state == "running"
    }

    func retainedStatus(title: String) -> String {
        "Last reported: \(title)"
    }

    /// The store-wide title comes from the reducer's state copy; a daemon that
    /// predates it gets a named absence, never the capitalized key.
    static func overallTitle(_ snapshot: V1IngestionSnapshot) -> String {
        PayloadAbsence.text(snapshot.stateTitle) ?? "Source status not reported"
    }

    /// A source's title is the reducer's `state_title`; a daemon that predates
    /// it gets a named absence, never a capitalized key.
    static func sourceTitle(_ source: V1IngestionSource) -> String {
        PayloadAbsence.text(source.stateTitle) ?? "Source state not reported"
    }

    /// The watcher's title is the reducer's `state_title`, or a named absence.
    static func watcherTitle(_ watcher: V1IngestionWatcher?) -> String {
        PayloadAbsence.text(watcher?.stateTitle) ?? "Watcher state not reported"
    }
}

// MARK: - Pane

struct SourcesPane: View {
    var onSetup: (() -> Void)? = nil
    @Environment(DashboardStore.self) var dashboard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var scaledMonogramSize: CGFloat = 36
    private var stacksRows: Bool { dynamicTypeSize.isAccessibilitySize }
    private var monogramSize: CGFloat {
        WorkTypeScale.resolved(base: 36, systemScaled: scaledMonogramSize, dynamicTypeSize: dynamicTypeSize)
    }
    /// The narrow retry's one name, used by the button and by the copy that
    /// tells the reviewer which control to press.
    static let retrySourceHealthTitle = "Retry source health"

    private var presentation: SourceHealthPresentation {
        SourceHealthPresentation(refreshError: dashboard.ingestionError)
    }

    var body: some View {
        ScrollBox {
            VStack(alignment: .leading, spacing: 0) {
                header
                content.padding(.top, Space.xl)
            }
            .padding(Space.gutter)
            .pageFrame()
        }
        .workFont(.body)
    }

    private func adaptiveRow<Content: View>(spacing: CGFloat, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) -> some View {
        let layout = stacksRows
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        return layout { content() }
    }

    private var header: some View {
        adaptiveRow(spacing: Space.l) {
        VStack(alignment: .leading, spacing: 6) {
            Text("Evidence sources")
                .workFont(.titlePage).tracking(Type.titlePageTracking)
                .foregroundStyle(Theme.ink)
            Text("Recording connections and local import health")
                .workFont(FieldFont.subtitle).foregroundStyle(Theme.muted)
        }
        if !stacksRows { Spacer() }
        // No second bare refresh glyph here. The window's ⌘R refresh already
        // re-requests source health (DashboardStore.refresh runs
        // refreshIngestion), so this page carried an identical, unlabelled
        // icon whose narrower scope only a hover tooltip could explain (K83).
        // The narrow retry survives as a NAMED button, and only in the state
        // where it does something the reviewer is waiting for.
        if dashboard.ingestionError != nil {
            Button(Self.retrySourceHealthTitle) { Task { await dashboard.refreshIngestion() } }
                .buttonStyle(QuietButtonStyle(tint: Theme.accent, horizontalPadding: 8))
                .disabled(dashboard.isRefreshingIngestion || dashboard.isOfflineSnapshot || SnapshotMode.enabled)
                .accessibilityIdentifier("sources.refresh")
        }
        if let onSetup {
            Button("Connections", action: onSetup).buttonStyle(NativeSetupActionStyle())
                .accessibilityIdentifier("sources.connections")
        }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = dashboard.ingestion {
            if let error = dashboard.ingestionError {
                retainedHealthBanner(error).padding(.bottom, Space.l)
            }
            issuesCard(snapshot.issues ?? []).padding(.bottom, (snapshot.issues ?? []).isEmpty ? 0 : Space.l)
            connectedCard(snapshot)
            watcherCard(snapshot.watcher).padding(.top, Space.xl)
            verificationDisclosure.padding(.top, Space.xl)
            scopeCard.padding(.top, Space.xl)
        } else if let error = dashboard.ingestionError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Source health unavailable").workFont(.rowLabel).foregroundStyle(Theme.ink)
                Text(error).workFont(.caption).foregroundStyle(Theme.muted)
                Text("Reconnect the recorder, then \(Self.retrySourceHealthTitle) or refresh the window (\(RefreshCommandText.shortcut)) to load current diagnostics.")
                    .workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            verificationDisclosure.padding(.top, Space.xl)
            scopeCard.padding(.top, Space.xl)
        } else {
            loadingScaffold
            verificationDisclosure.padding(.top, Space.xl)
            scopeCard.padding(.top, Space.xl)
        }
    }

    /// Before the first /v1/ingestion answer the page keeps its sections, each
    /// with a named "not yet loaded" value, instead of collapsing to one line.
    private var loadingScaffold: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    adaptiveRow(spacing: Space.s) {
                        Text("Connected sources").workFont(.titleCard).foregroundStyle(Theme.ink)
                        if !stacksRows { Spacer() }
                        notYetLoadedLozenge
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.m)
                    .frame(minHeight: 52)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, Space.xl)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source list not yet loaded")
                            .workFont(.rowLabel).foregroundStyle(Theme.ink)
                        Text("Loading source health from the recorder.")
                            .workFont(.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Card(padding: Space.xl) {
                VStack(alignment: .leading, spacing: 0) {
                    adaptiveRow(spacing: Space.s) {
                        Text("Continuous sync").workFont(.titleCard).foregroundStyle(Theme.ink)
                        if !stacksRows { Spacer() }
                        notYetLoadedLozenge
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, Space.m)
                    Text("Watcher status not yet loaded.")
                        .workFont(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Space.xl)
        }
        .accessibilityIdentifier("sources-loading")
    }

    private var notYetLoadedLozenge: some View {
        StateLozenge(text: "Not yet loaded", tone: .quiet)
    }

    // MARK: connected sources

    private func retainedHealthBanner(_ error: String) -> some View {
        Card(padding: Space.l) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Current source health unavailable").workFont(.rowLabel).foregroundStyle(Theme.ink)
                    Text("Showing the previous source snapshot. Statuses below are last reported; current recording and watcher health are unconfirmed.")
                        .workFont(.body).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(error).workFont(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("sources-retained-health")
    }

    private func connectedCard(_ snapshot: V1IngestionSnapshot) -> some View {
        let sources = (snapshot.sources ?? []).sorted { $0.source < $1.source }
        let watcherRunning = presentation.watcherIsCurrentlyRunning(snapshot.watcher)
        return Card(padding: 0) {
            VStack(spacing: 0) {
                adaptiveRow(spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Text(presentation.isRetained ? "Last reported sources" : "Connected sources").workFont(.titleCard).foregroundStyle(Theme.ink)
                        Text("\(sources.count)").workFont(.dataSmall).foregroundStyle(Theme.muted)
                    }
                    if !stacksRows { Spacer() }
                    if let overall = snapshot.state {
                        overallLozenge(overall, title: SourceHealthPresentation.overallTitle(snapshot), watcherRunning: watcherRunning)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.m)
                .frame(minHeight: 52)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = snapshot.stateDetail {
                    Text(detail)
                        .workFont(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.xl)
                        .padding(.bottom, Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, Space.xl)
                if sources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No import sources configured")
                            .workFont(.rowLabel).foregroundStyle(Theme.ink)
                        Text("Use Connections to add a coding client.")
                            .workFont(.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                                .padding(.horizontal, Space.xl)
                        }
                        sourceRow(source, watcherRunning: watcherRunning)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: V1IngestionSource, watcherRunning: Bool) -> some View {
        adaptiveRow(spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.l) {
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .fill(Theme.tintNeutral)
                    .frame(width: monogramSize, height: monogramSize)
                    .overlay(
                        Text(Self.monogram(source.source))
                            .workFont(.dataSmallSemibold).foregroundStyle(Theme.muted)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.source).workFont(.rowLabel).foregroundStyle(Theme.ink)
                    Text(sourceDetail(source, watcherRunning: watcherRunning))
                        .workFont(.dataSmall).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !stacksRows { Spacer() }
            VStack(alignment: stacksRows ? .leading : .trailing, spacing: 4) {
                if let ago = agoText(source.lastSuccessAt) {
                    Text("last import \(ago)").workFont(.dataSmall).foregroundStyle(Theme.muted)
                } else {
                    // A named absence, not a timestamp: prose face (K10).
                    Text("no successful import yet").workFont(FieldFont.absence).foregroundStyle(Theme.muted)
                }
                if let errors = source.errorCount, errors > 0 {
                    Text("\(errors) error\(errors == 1 ? "" : "s")")
                        .workFont(.dataSmall).foregroundStyle(presentation.isRetained ? Theme.muted : Theme.coral)
                }
            }
            sourceLozenge(source, watcherRunning: watcherRunning)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.s)
        .frame(minHeight: Metrics.rowSource)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Two-letter monogram that actually distinguishes sources: hyphenated
    /// names take their parts' initials (claude-code → CC); plain names take
    /// first + last letter (opencode → OE, openclaw → OW, codex → CX).
    static func monogram(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" })
        if parts.count >= 2 {
            return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        }
        guard let first = name.first, let last = name.last, name.count > 1 else {
            return name.uppercased()
        }
        return String([first, last]).uppercased()
    }

    /// The row's fact line, built only from reported numbers. "watched" is a
    /// live claim, so it degrades to "configured" while the importer is down.
    private func sourceDetail(_ source: V1IngestionSource, watcherRunning: Bool) -> String {
        var parts: [String] = []
        if let scope = source.scope {
            parts.append(scope == "watched" && !watcherRunning ? "configured" : scope)
        }
        if let discovered = source.discovered { parts.append("\(discovered) files discovered") }
        if let parsed = source.parsed { parts.append("\(parsed) parsed") }
        if let skipped = source.skipped, skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.isEmpty ? "no scan recorded" : parts.joined(separator: " · ")
    }

    /// Per-source lozenge. The words are the reducer's `state_title`; the tint
    /// follows the live-fact rule — green only for a healthy source under a
    /// running watcher that actually parsed rows, amber for degraded.
    @ViewBuilder
    private func sourceLozenge(_ source: V1IngestionSource, watcherRunning: Bool) -> some View {
        let title = SourceHealthPresentation.sourceTitle(source)
        if presentation.isRetained {
            StateLozenge(text: presentation.retainedStatus(title: title), tone: .quiet)
        } else {
            switch source.state ?? "unknown" {
            case "healthy" where watcherRunning && (source.parsed ?? 0) > 0:
                StateLozenge(text: title, tone: .connected)
            case "degraded":
                StateLozenge(text: title, tone: .warning)
            default:
                StateLozenge(text: title, tone: .quiet)
            }
        }
    }

    /// The card-level roll-up follows the same live-fact rule.
    @ViewBuilder
    private func overallLozenge(_ state: String, title: String, watcherRunning: Bool) -> some View {
        if presentation.isRetained {
            StateLozenge(text: presentation.retainedStatus(title: title), tone: .quiet)
        } else {
            // Words from the reducer's `state_title`; green stays a live fact.
            switch state {
            case "healthy" where watcherRunning:
                StateLozenge(text: title, tone: .connected)
            case "degraded":
                StateLozenge(text: title, tone: .warning)
            default:
                StateLozenge(text: title, tone: .quiet)
            }
        }
    }

    // MARK: watcher

    @ViewBuilder
    private func watcherCard(_ watcher: V1IngestionWatcher?) -> some View {
        Card(padding: Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                adaptiveRow(spacing: Space.s) {
                    Text("Continuous sync").workFont(.titleCard).foregroundStyle(Theme.ink)
                    if !stacksRows { Spacer() }
                    if presentation.isRetained {
                        StateLozenge(text: presentation.retainedStatus(title: SourceHealthPresentation.watcherTitle(watcher)), tone: .quiet)
                    } else {
                        let watcherTitle = SourceHealthPresentation.watcherTitle(watcher)
                        switch watcher?.state {
                        case "running":
                            StateLozenge(text: watcherTitle, tone: .connected)
                        case "stale":
                            StateLozenge(text: watcherTitle, tone: .warning)
                        case "stopped":
                            StateLozenge(text: watcherTitle, tone: .failure)
                        default:
                            StateLozenge(text: watcherTitle, tone: .quiet)
                        }
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, Space.m)
                Text(watcherDetail(watcher))
                    .workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The reducer's watcher sentence (`state_detail`) followed by the
    /// recorded heartbeat and cadence — facts, not vocabulary.
    private func watcherDetail(_ watcher: V1IngestionWatcher?) -> String {
        guard let watcher else { return "The daemon reported no watcher block." }
        let heartbeat = agoText(watcher.heartbeatAt).map { "last heartbeat \($0)" } ?? "no heartbeat recorded"
        if presentation.isRetained {
            return "Previous snapshot: \(SourceHealthPresentation.watcherTitle(watcher)) · \(heartbeat). Current watcher activity is unconfirmed."
        }
        let sentence = PayloadAbsence.text(watcher.stateDetail) ?? "Watcher state detail not reported."
        if watcher.state == "not_configured" { return sentence }
        let cadence = watcher.intervalSeconds.map { " · expected every \(Int($0.rounded()))s" } ?? ""
        return "\(sentence) \(heartbeat)\(cadence)"
    }

    // MARK: issues

    @ViewBuilder
    private func issuesCard(_ issues: [V1IngestionIssue]) -> some View {
        if !issues.isEmpty {
            let groups = SourceIssueGroup.group(issues)
            Card(padding: Space.xl) {
                VStack(alignment: .leading, spacing: 0) {
                    adaptiveRow(spacing: Space.s, alignment: .firstTextBaseline) {
                        Text("\(presentation.isRetained ? "Previously reported" : "Needs attention") (\(groups.count))")
                            .workFont(.titleCard).foregroundStyle(Theme.ink)
                        Text("\(issues.count) diagnostic \(issues.count == 1 ? "report" : "reports")")
                            .workFont(.caption).foregroundStyle(Theme.muted)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, Space.m)
                    VStack(alignment: .leading, spacing: Space.xl) {
                        ForEach(groups) { group in
                            if group.isGlobalReconciliation {
                                sharedReconciliationIssue(group)
                            } else if let issue = group.issues.first {
                                originalDiagnostic(issue)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sharedReconciliationIssue(_ group: SourceIssueGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Evidence reconciliation needs review")
                .workFont(.rowLabel).foregroundStyle(presentation.isRetained ? Theme.muted : Theme.amber)
            Text(group.affectedSources.isEmpty
                ? "One global reconciliation fault is reported. Affected sources were not identified."
                : "One global reconciliation fault is reported across \(group.affectedSources.count) source \(group.affectedSources.count == 1 ? "summary" : "summaries").")
                .workFont(.body).foregroundStyle(Theme.ink)
            if !group.affectedSources.isEmpty {
                Text("Affected sources: \(group.affectedSources.joined(separator: ", "))")
                    .workFont(.caption).foregroundStyle(Theme.muted)
            }
            Text("Usage history may be incomplete or conflicting. This shared fault does not establish that every affected client stopped recording.")
                .workFont(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Space.l) {
                    ForEach(Array(group.issues.enumerated()), id: \.offset) { _, issue in
                        originalDiagnostic(issue)
                    }
                }
                .padding(.top, Space.m)
            } label: {
                Text("Original diagnostics (\(group.issues.count))")
                    .workFont(.captionSemibold).foregroundStyle(Theme.ink)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sources-reconciliation-diagnostics")
        }
    }

    private func originalDiagnostic(_ issue: V1IngestionIssue) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(issueTitle(issue))
                .workFont(.rowLabel).foregroundStyle(presentation.isRetained ? Theme.muted : Theme.amber)
            Text(issue.code ?? "code not supplied").workFont(.dataSmall).foregroundStyle(Theme.muted)
            Text(issue.action ?? "See agentacct doctor for source diagnostics.")
                .workFont(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    /// Human phrasing first; the raw code stays beside it for diagnostics.
    private func issueTitle(_ issue: V1IngestionIssue) -> String {
        let phrase = (issue.code ?? "issue")
            .replacingOccurrences(of: "_", with: " ")
        let sentence = phrase.prefix(1).uppercased() + phrase.dropFirst()
        if let source = issue.source {
            return "\(sentence) — \(source)"
        }
        return sentence
    }

    // MARK: verifier shelf

    private var verificationDisclosure: some View {
        DisclosureGroup("Verification connections · not connected") {
            verifierShelf.padding(.top, Space.m)
        }
        .workFont(.caption)
        .accessibilityIdentifier("sources.verification-connections")
    }

    private var verifierShelf: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Independent evidence can support verification. These connections are not configured.")
                .workFont(.caption).foregroundStyle(Theme.muted)
            adaptiveRow(spacing: Space.xl, alignment: .top) {
                verifierCard(
                    name: "CI check runs",
                    provides: "independent check results recorded against receipts"
                )
                verifierCard(
                    name: "Human reviewer",
                    provides: "finding review and approval dispositions"
                )
            }
        }
    }

    private func verifierCard(name: String, provides: String) -> some View {
        Card(padding: Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                adaptiveRow(spacing: Space.m) {
                    RoundedRectangle(cornerRadius: Metrics.radius)
                        .fill(Theme.tintNeutral)
                        .frame(width: monogramSize, height: monogramSize)
                        .overlay(
                            // Not connected yet: a verifier slot, not a tier.
                            Image(systemName: "link")
                                .workFont(.icon).foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).workFont(.rowLabel).foregroundStyle(Theme.ink)
                        Text(provides).workFont(.dataSmall).foregroundStyle(Theme.muted)
                    }
                    if !stacksRows { Spacer() }
                    HStack(spacing: 6) {
                        // The tier this verifier WOULD produce, drawn inactive.
                        EvidencePip(grade: "externally_verified", inactive: true)
                        Text("→ verified").workFont(.captionSemibold).foregroundStyle(Theme.muted)
                    }
                }

            }
        }
    }

    // MARK: scope transparency

    private var scopeCard: some View {
        Card(padding: Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                adaptiveRow(spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        StatusDot(color: Theme.green, size: 8)
                        Text("Local evidence store")
                            .workFont(.rowLabel).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        ContextHelp(title: "What is stored locally",
                            message: "Imports activity and usage from local client logs, plus work sections and checks reported by agents. Records can include summaries, commands, file paths, exit codes and artifact references.",
                            identifier: "sources.capture-scope")
                    }
                    if !stacksRows { Spacer() }
                    Text("store: \(SnapshotMode.enabled ? "/synthetic-review/state" : ((try? GlanceClient.storeDir())?.path ?? "invalid configuration"))")
                        .workFont(.dataSmall).foregroundStyle(Theme.muted)
                        .lineLimit(stacksRows ? nil : 1).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: stacksRows ? .infinity : 420, alignment: stacksRows ? .leading : .trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A v7 status lozenge: h22 rx4 tint wash, marker + 12/600 text. A source or
/// watcher state is NOT an evidence tier (K05): only a live connection wears
/// the green `StatusDot`; every other state carries the flat minus marker,
/// never a pip shape.
struct StateLozenge: View {
    enum Tone {
        case connected, warning, failure, quiet

        var tint: Color {
            switch self {
            case .connected: return Theme.green
            case .warning: return Theme.amber
            case .failure: return Theme.coral
            case .quiet: return Theme.muted
            }
        }

        var wash: Color {
            switch self {
            case .connected: return Theme.tintGreen
            case .warning: return Theme.tintAmber
            case .failure: return Theme.tintCoral
            case .quiet: return Theme.tintNeutral
            }
        }
    }

    let text: String
    let tone: Tone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var scaledMinimumHeight = Metrics.tierBadgeH

    var body: some View {
        HStack(spacing: 6) {
            if tone == .connected {
                StatusDot(color: Theme.green)
            } else {
                DisconnectedMarker(tint: tone.tint)
            }
            Text(text).workFont(.captionSemibold).foregroundStyle(tone.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
        .frame(minHeight: WorkTypeScale.resolved(base: Metrics.tierBadgeH, systemScaled: scaledMinimumHeight, dynamicTypeSize: dynamicTypeSize))
        .background(tone.wash, in: RoundedRectangle(cornerRadius: Metrics.radius))
    }
}
