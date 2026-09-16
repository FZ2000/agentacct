import SwiftUI
import AppKit

// The Work surface — one receipts collection in three adaptive presentations:
//
// * No Task selected → the task collection.
// * A Task selected at a wide width → a resizable master list and the record.
// * A Task selected at a compact width or accessibility text size → the record
//   is pushed over the collection, with an explicit route back.
//
// A Task is the converged unit (root session + continuations + subagents).
// Honesty rides the payload: decision words come from the daemon, evidence
// tiers keep their pip shapes, and absent facts are named, never zeroed.

enum WorkSessionResolution: Equatable {
    case task(String)
    case unresolved(String)
}

enum WorkRecordPhaseKey: Hashable {
    case loading(taskId: String)
    case loaded(taskId: String)
    case failed(taskId: String)
    case unresolved(sessionId: String)
    case empty
}

func workRecordPhaseKey(
    selectedTaskId: String?,
    sessionId: String?,
    unresolvedSessionId: String?,
    receiptTaskId: String?,
    errorPresent: Bool
) -> WorkRecordPhaseKey {
    if let selectedTaskId {
        if receiptTaskId == selectedTaskId { return .loaded(taskId: selectedTaskId) }
        if errorPresent { return .failed(taskId: selectedTaskId) }
        return .loading(taskId: selectedTaskId)
    }
    if let sessionId, sessionId == unresolvedSessionId {
        return .unresolved(sessionId: sessionId)
    }
    return .empty
}

func workSessionResolution(
    for sessionId: String,
    in tasks: [ReceiptSummary]
) -> WorkSessionResolution {
    if let match = tasks.first(where: { $0.primaryRoot?.sessionKey == sessionId }) {
        return .task(match.taskId)
    }
    return .unresolved(sessionId)
}

/// Lifecycle filter groups for the table tabs. A FILTER grouping only — rows
/// always wear the daemon's own decision word; keys outside every group land
/// in "Other" so the tab counts always sum to All (no receipt is hidden).
enum WorkGroup: String, CaseIterable, Identifiable {
    case attention = "Attention"
    case verified = "Verified"
    case reported = "Reported"
    case inProgress = "In progress"
    // The reducer's decision word for a Task with no work steps recorded
    // (`DECISION_LABELS["observed"]`), so the tab and its rows read alike.
    case observed = "No work recorded"
    case stopped = "Stopped"
    case other = "Other"

    var id: String { rawValue }

    /// The vocabulary's group key for this tab (`GROUP_DEFINITIONS`).
    var payloadKey: String {
        switch self {
        case .attention: return "attention"
        case .verified: return "verified"
        case .reported: return "reported"
        case .inProgress: return "in_progress"
        case .observed: return "observed"
        case .stopped: return "stopped"
        case .other: return "other"
        }
    }

    init?(payloadKey: String?) {
        guard let match = WorkGroup.allCases.first(where: { $0.payloadKey == payloadKey }) else { return nil }
        self = match
    }

    /// The payload's group label when the vocabulary legend carries one.
    func label(in legend: DecisionLegendPayload?) -> String {
        PayloadAbsence.text(legend?.groups.first(where: { $0.key == payloadKey })?.label) ?? rawValue
    }

    /// The reducer's filter group (`group_key`) — the vocabulary maps decision
    /// words and the attention predicate to groups; the app re-derives
    /// nothing. A row without a group key sits in "Other", never hidden.
    static func forTask(_ task: ReceiptSummary) -> WorkGroup {
        WorkGroup(payloadKey: task.groupKey) ?? .other
    }
}

/// The Work surface's shared sort modes. One `WorkBrowseState` drives both the
/// receipts table and compact master, so detail round-trips preserve order.
enum WorkSort: String, CaseIterable, Identifiable {
    case attention, latest, cost
    var id: String { rawValue }

    /// The sort rule shown in the footer. The attention rule is the
    /// vocabulary's (`queue.sort_text`), stated from the reducer's order.
    func footerText(queue: AttentionQueueCopy?) -> String {
        switch self {
        case .attention: return PayloadAbsence.text(queue?.sortText) ?? "attention order not reported"
        case .latest: return "most recent first"
        case .cost: return "highest estimated cost first"
        }
    }
}

/// Durable state for the Work collection. Selection can change the collection's
/// layout, but it must never destroy the user's query, grouping, order, or
/// one-shot return-focus request. AppSelection owns one instance for the
/// lifetime of the main window.
@MainActor
final class WorkBrowseState: ObservableObject {
    @Published var query = ""
    @Published var group: WorkGroup?
    @Published var sort: WorkSort = .latest
    @Published var pendingFocusRestorationTaskId: String?
    @Published var shouldFocusSearchOnReturn = false

    func visibleTasks(
        in tasks: [ReceiptSummary],
        attention: V1AttentionPayload? = nil
    ) -> [ReceiptSummary] {
        WorkTaskPresentation(
            tasks: tasks,
            attention: attention,
            group: group,
            query: query,
            sort: sort
        ).visibleTasks
    }

    func prepareReturnFocus(
        from taskId: String?,
        in tasks: [ReceiptSummary],
        attention: V1AttentionPayload? = nil
    ) {
        let visible = visibleTasks(in: tasks, attention: attention)
        if let taskId, visible.contains(where: { $0.taskId == taskId }) {
            pendingFocusRestorationTaskId = taskId
            shouldFocusSearchOnReturn = false
        } else {
            pendingFocusRestorationTaskId = nil
            shouldFocusSearchOnReturn = true
        }
    }
}

func visibleWorkReceipts(
    _ tasks: [ReceiptSummary],
    query: String,
    group: WorkGroup?,
    sort: WorkSort
) -> [ReceiptSummary] {
    var rows = tasks
    if let group {
        rows = rows.filter { WorkGroup.forTask($0) == group }
    }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !needle.isEmpty {
        rows = rows.filter {
            ($0.title ?? "").lowercased().contains(needle)
                || $0.taskId.lowercased().contains(needle)
                || ($0.primaryRoot?.client ?? "").lowercased().contains(needle)
        }
    }
    return sortedReceipts(rows, by: sort)
}

func workSelectionIsOutsideBrowse(
    taskId: String?,
    allTasks: [ReceiptSummary],
    visibleTasks: [ReceiptSummary]
) -> Bool {
    guard let taskId, allTasks.contains(where: { $0.taskId == taskId }) else { return false }
    return !visibleTasks.contains(where: { $0.taskId == taskId })
}

func workReceiptCollectionIsPartial(loaded: Int, total: Int?, truncated: Bool?) -> Bool {
    truncated == true || total.map { $0 > loaded } == true
}

/// Whether a receipts page has actually loaded. While the first request is
/// still out — or after it failed with nothing retained — there is no page to
/// count, and a lifecycle "0" would be a reported result rather than a named
/// absence (K54). A refresh that fails over a loaded page keeps its counts.
func workReceiptPageIsLoaded(loadedCount: Int, isLoading: Bool, error: String?) -> Bool {
    loadedCount > 0 || !(isLoading || error != nil)
}

func workBrowseCountText(
    visible: Int,
    loaded: Int,
    total: Int?,
    truncated: Bool?,
    pageIsLoaded: Bool = true
) -> String {
    // No page has arrived yet (or the request failed with nothing retained):
    // a count of 0 would claim a result the store never reported (K54).
    guard pageIsLoaded else { return "tasks not loaded" }
    let loadedCount = visible == loaded ? "\(loaded) loaded" : "\(visible) of \(loaded) loaded"
    if workReceiptCollectionIsPartial(loaded: loaded, total: total, truncated: truncated) {
        guard let total else { return "\(loadedCount) · more may exist" }
        return "\(visible) of \(loaded) loaded · \(total) in store"
    }
    guard let total else { return "\(loadedCount) · total not reported" }
    if total < loaded {
        return "\(loadedCount) · \(total) total reported"
    }
    return "\(visible) of \(total) tasks"
}

func workReceiptRefreshError(
    selectedTaskId: String?,
    errorTaskId: String?,
    error: String?
) -> String? {
    guard selectedTaskId != nil, selectedTaskId == errorTaskId else { return nil }
    return error
}

enum WorkLayoutMode: Equatable {
    case table
    case split
    case pushDetail
}

func workLayoutMode(
    for availableWidth: CGFloat,
    dynamicTypeSize: DynamicTypeSize,
    hasSelection: Bool
) -> WorkLayoutMode {
    guard hasSelection else { return .table }
    if dynamicTypeSize.isAccessibilitySize || availableWidth < 1_080 {
        return .pushDetail
    }
    return .split
}

/// One semantic row contract for both the task collection and compact master.
/// When the selected receipt has richer/fresher detail, its evidence, check, and
/// cost values replace the compact summary so adjacent UI cannot disagree.
/// Every display string is the reducer's; this only chooses which to show.
struct WorkReceiptRowPresentation {
    let taskId: String
    let title: String
    let decisionKey: String
    let decisionLabel: String
    let decisionHelp: String
    let evidence: ReceiptEvidence
    /// The reducer's handoff marker words (nil when the decision already says it).
    let lifecycleMarkerText: String?
    let coverageText: String
    let coverageQualifier: String
    /// Whether `coverageText` is a measured figure or a named state — the
    /// reducer-side role that decides its FACE (K10).
    let coverageIsMetric: Bool
    let coverageIsInconsistent: Bool
    /// The strongest evidence tier key and its label (nil when none is proven).
    let strongestTier: String?
    let strongestTierLabel: String?
    let checkRunsText: String
    let checkRunsValue: String
    let checkRunsQualifier: String
    let checkRunsAreInconsistent: Bool
    let compactCheckRunsText: String
    /// Whether the check tally reads as a measured figure or a named state —
    /// mapped ONCE from the payload's `check_runs_state` key, so every branch
    /// of the cell (wrapped, stacked or single line) takes the same face (K10).
    var checkRunsIsMetric: Bool {
        !checkRunsAreInconsistent && !["none", "not_reported"].contains(checkRunsState ?? "")
    }
    /// `failed` / `passed` / `not_reported` / `none` — the one key the tint maps.
    let checkRunsState: String?
    let clientText: String
    /// The cost line with its basis (`≈$10.77 · pricing estimate`) or the
    /// reducer's named absence.
    let costText: String
    /// The bare cost figure for a table cell, or the named absence.
    let costDisplayText: String
    let costBasisLabel: String?
    let costIsAbsent: Bool
    /// The verdict's unproven part (`Not yet proven — …`), nil when none.
    let gapLine: String?
    /// What the ratio does not cover, owing no proof claim, nil when none.
    let ledgerText: String?
    let updatedText: String
    let updatedAccessibilityText: String
    let attentionReason: String?
    /// Coral for a recorded failure, blocker or failed step; muted for a
    /// check that could not run (the reducer's `not_run` tone).
    let attentionReasonTint: Color
    let fieldLabels: ReceiptFieldLabels

    /// - Parameter listLabels: the field headers `/v1/tasks` ships for the LIST
    ///   (`TASK_LIST_FIELD_LABELS`). A row without its detail receipt used to
    ///   fall back to the Swift defaults in `ReceiptFieldLabels`, so the
    ///   accessibility-size rows spoke the app's own words for Client, Updated
    ///   and Attention while the visible column headers came from the payload.
    init(task: ReceiptSummary, detail: Receipt? = nil, listLabels: ReceiptFieldLabels? = nil) {
        let selectedDetail = detail?.taskId == task.taskId ? detail : nil
        let decision = selectedDetail?.axes.decisionStatus ?? task.decisionStatus
        let resolvedEvidence = selectedDetail?.axes.evidenceStrength ?? task.evidenceStrength

        taskId = task.taskId
        title = selectedDetail?.title ?? task.title ?? task.taskId
        decisionKey = decision.key
        decisionLabel = decision.label ?? decision.key
        decisionHelp = decision.statement ?? ""
        evidence = resolvedEvidence
        lifecycleMarkerText = PayloadAbsence.text(selectedDetail?.lifecycleMarkerText ?? task.lifecycleMarkerText)
        fieldLabels = selectedDetail?.fieldLabels ?? listLabels ?? ReceiptFieldLabels()

        let coveragePresentation = ReceiptCoveragePresentation(evidence: resolvedEvidence)
        coverageText = coveragePresentation.rowText
        coverageQualifier = coveragePresentation.qualifier
        coverageIsMetric = coveragePresentation.valueIsMetric
        coverageIsInconsistent = coveragePresentation.isInconsistent
        strongestTier = PayloadAbsence.text(resolvedEvidence.strongestTier)
        strongestTierLabel = resolvedEvidence.strongestTierLabel
            ?? strongestTier.map { EvidenceTierStyle.forGrade($0).label }

        let checkRunsPresentation: ReceiptCheckRunsPresentation
        if let detailChecks = selectedDetail?.dimensions.evidence,
           detailChecks.checksTile != nil || detailChecks.checksTotal != nil {
            checkRunsPresentation = ReceiptCheckRunsPresentation(evidence: detailChecks)
            checkRunsState = detailChecks.checkRunsState ?? resolvedEvidence.checkRunsState
        } else {
            checkRunsPresentation = ReceiptCheckRunsPresentation(strength: resolvedEvidence)
            checkRunsState = resolvedEvidence.checkRunsState
        }
        checkRunsText = checkRunsPresentation.rowText
        checkRunsValue = checkRunsPresentation.value
        checkRunsQualifier = checkRunsPresentation.qualifier
        checkRunsAreInconsistent = checkRunsPresentation.isInconsistent
        compactCheckRunsText = checkRunsPresentation.headerText

        clientText = task.primaryRoot?.client ?? "unattributed"
        if let cost = selectedDetail?.dimensions.cost {
            costText = cost.text
            costDisplayText = PayloadAbsence.text(cost.displayText) ?? PayloadAbsence.cost
            costBasisLabel = cost.isAbsent ? nil : PayloadAbsence.text(cost.basisLabel)
            costIsAbsent = cost.isAbsent
        } else {
            costText = task.cost.text
            costDisplayText = PayloadAbsence.text(task.cost.displayText) ?? PayloadAbsence.cost
            costBasisLabel = task.cost.isAbsent ? nil : PayloadAbsence.text(task.cost.basisLabel)
            costIsAbsent = task.cost.isAbsent
        }
        gapLine = (selectedDetail?.verdict ?? task.verdict)?.gapLine
        ledgerText = PayloadAbsence.text((selectedDetail?.verdict ?? task.verdict)?.ledgerText)
        updatedText = agoText(task.lastActivityAt) ?? PayloadAbsence.activityTime
        updatedAccessibilityText = task.lastActivityAt == nil
            ? PayloadAbsence.activityTime : "updated \(updatedText)"

        // The reducer's one attention block states the reason. A DISPOSITION is
        // a judgement about that finding, not a deletion of it: the row used to
        // drop the reason entirely once a finding was marked reviewed, leaving
        // the coral decision badge standing with no visible cause anywhere on
        // the surface (C4). The facts stay; only the tone changes, because a
        // reviewed item no longer needs you today.
        let leadAttention = selectedDetail?.attention ?? task.attention
        let attentionIsOpen = leadAttention?.open ?? true
        let attentionIsFailure = leadAttention?.resultTone
            .map { CheckResultTone(payload: $0) == .failure } != false
        attentionReasonTint = attentionIsOpen && attentionIsFailure ? Theme.coral : Theme.muted
        if let attention = leadAttention {
            let reason = [PayloadAbsence.text(attention.reasonLabel), PayloadAbsence.text(attention.summary)]
                .compactMap { $0 }
                .joined(separator: " — ")
            attentionReason = reason.isEmpty ? PayloadAbsence.text(attention.label) : reason
        } else if (selectedDetail?.attentionOpen ?? task.attentionOpen) == nil,
                  (decision.blocker?.disposition?.state ?? "open") != "resolved",
                  let blocker = PayloadAbsence.text(decision.blocker?.text) {
            // An older payload without the attention block: the standing
            // blocker's own words are still a recorded fact.
            attentionReason = blocker
        } else {
            attentionReason = nil
        }
    }

    /// What the row IS and what was decided — the two facts a reviewer needs
    /// to decide whether to open it. The measured fields ride as named custom
    /// content instead of one ~900-character sentence (K119); the self-naming
    /// verdict lines stay here because they carry their own subject.
    var accessibilityLabel: String {
        joinedRecordedSentences([
            title,
            decisionLabel,
            lifecycleMarkerText,
            gapLine,
            ledgerText,
        ])
    }

    /// The row's remaining visible facts, each under the field name its column
    /// header prints (the payload's `field_labels`, never a Swift word). Order
    /// follows the row: why it needs review, then the two axes, then
    /// provenance, cost and recency.
    var accessibilityFields: [WorkRowAccessibilityField] {
        var fields: [WorkRowAccessibilityField] = []
        if let attentionReason, !attentionReason.isEmpty {
            // The reason a row is in the queue is spoken with the row.
            fields.append(.init(label: fieldLabels.attentionLabel, value: attentionReason, isPrimary: true))
        }
        // Shape-carried facts get their textual twin (the pip is hidden).
        let coverage = strongestTierLabel.map { "\(coverageText), strongest evidence \($0)" } ?? coverageText
        fields.append(.init(label: fieldLabels.coverageLabel, value: coverage))
        fields.append(.init(
            label: fieldLabels.checksLabel,
            value: checkRunsText.replacingOccurrences(of: " · ", with: ", ")
        ))
        fields.append(.init(label: fieldLabels.clientLabel, value: clientText))
        fields.append(.init(label: fieldLabels.costLabel, value: costText))
        fields.append(.init(label: fieldLabels.updatedLabel, value: updatedAccessibilityText))
        return fields
    }
}

/// One named fact of a list row, for assistive technology: the field name its
/// column header prints and the value the cell shows.
struct WorkRowAccessibilityField {
    let label: String
    let value: String
    /// Spoken with the row rather than only on request.
    var isPrimary = false
}

/// One custom-content slot. A missing field leaves the view untouched, so the
/// chain below keeps a static view type (no AnyView in a scrolling table).
private struct WorkRowAccessibilityFieldSlot: ViewModifier {
    let field: WorkRowAccessibilityField?

    func body(content: Content) -> some View {
        if let field {
            content.accessibilityCustomContent(
                Text(field.label),
                Text(field.value),
                importance: field.isPrimary ? .high : .default
            )
        } else {
            content
        }
    }
}

extension View {
    /// Attach a row's named facts as accessibility custom content, so each one
    /// is announced with its field name and none of them lengthen the label.
    /// The slot count matches the row contract in `accessibilityFields`.
    func workRowAccessibilityFields(_ fields: [WorkRowAccessibilityField]) -> some View {
        func slot(_ index: Int) -> WorkRowAccessibilityFieldSlot {
            WorkRowAccessibilityFieldSlot(field: index < fields.count ? fields[index] : nil)
        }
        return modifier(slot(0)).modifier(slot(1)).modifier(slot(2))
            .modifier(slot(3)).modifier(slot(4)).modifier(slot(5))
    }
}

/// Join recorded sentences into one spoken line. A part that already ends in
/// terminal punctuation keeps its own full stop instead of collecting a second
/// one — the doubled ".." VoiceOver read out on attention rows (K119).
func joinedRecordedSentences(_ parts: [String?]) -> String {
    let kept = parts
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return kept.enumerated().reduce(into: "") { text, entry in
        let (index, part) = entry
        text += part
        guard index < kept.count - 1 else { return }
        text += part.hasSuffix(".") || part.hasSuffix("!") || part.hasSuffix("?") || part.hasSuffix(":")
            ? " " : ". "
    }
}

/// The receipt's two evidence dimensions in decision language. Claim coverage
/// and recorded check runs are deliberately separate so `0/1 supported` can
/// never look like it contradicts `9/11 checks passed`.
struct WorkReceiptDecisionPresentation {
    let headline: String
    let explanation: String
    let coverageValue: String
    let coverageQualifier: String
    let checksValue: String
    let checksQualifier: String
    let isAttention: Bool

    init(receipt: Receipt) {
        let decision = receipt.axes.decisionStatus
        let coverage = receipt.axes.evidenceStrength
        let checks = receipt.dimensions.evidence
        // The reducer predicate is the only "needs you" signal; without it
        // the decision word's own bucket decides (no Swift re-derivation).
        isAttention = receipt.attentionOpen ?? receipt.attention?.open
            ?? (receipt.groupKey == WorkGroup.attention.payloadKey)
        headline = isAttention ? "Why this needs attention" : "Current outcome"
        let statement = decision.statement ?? "No decision explanation was recorded."
        if let assertedBy = PayloadAbsence.text(decision.assertedByLabel) {
            explanation = "\(statement) — \(assertedBy)"
        } else {
            explanation = statement
        }

        let coveragePresentation = ReceiptCoveragePresentation(evidence: coverage)
        coverageValue = coveragePresentation.value
        coverageQualifier = coveragePresentation.qualifier

        let checksPresentation = ReceiptCheckRunsPresentation(evidence: checks)
        checksValue = checksPresentation.value
        checksQualifier = checksPresentation.qualifier
    }

    var accessibilityLabel: String {
        "\(headline). \(explanation). Coverage: \(coverageValue), \(coverageQualifier). "
            + "Checks: \(checksValue), \(checksQualifier)."
    }
}

struct WorkAttentionEmptyCopy: Equatable {
    let title: String
    let detail: String

    init(payload: V1AttentionPayload, query: String) {
        let noun = PayloadAbsence.text(payload.queue?.noun) ?? "the review queue"
        let count = PayloadAbsence.text(payload.queue?.countText) ?? "\(payload.total) in \(noun)"
        if payload.total == 0 {
            title = "Nothing in \(noun)"
            detail = "The complete attention projection reports no failed checks, failed steps, or unresolved blockers."
        } else if !query.isEmpty, !payload.items.isEmpty {
            title = "Nothing in \(noun) matches this filter"
            detail = "The bounded queue has \(payload.items.count) loaded of \(count); adjust the filter to inspect them."
        } else {
            title = "\(PayloadAbsence.text(payload.queue?.noun) ?? "Review queue") details unavailable"
            detail = "The complete projection reports \(count), but no bounded queue rows were returned. Refresh before acting."
        }
    }
}

/// Shared ordering for the receipts table and master — one algorithm, so the
/// two surfaces can never disagree. `.latest` is the daemon's own order
/// (last_activity_at desc); `.attention` sorts by the reducer's attention
/// order class (`attention_order`; rows with none last), then most recent, so
/// every filter shows a subsequence of the same order.
func sortedReceipts(_ rows: [ReceiptSummary], by sort: WorkSort) -> [ReceiptSummary] {
    switch sort {
    case .attention:
        return rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.attentionOrder ?? Int.max
            let right = rhs.element.attentionOrder ?? Int.max
            if left != right { return left < right }
            let leftTime = lhs.element.lastActivityAt ?? -Double.infinity
            let rightTime = rhs.element.lastActivityAt ?? -Double.infinity
            if leftTime != rightTime { return leftTime > rightTime }
            return lhs.offset < rhs.offset
        }.map(\.element)
    case .latest:
        return rows  // server order: recency
    case .cost:
        return rows.sorted { ($0.cost.estimatedCostUsd ?? -1) > ($1.cost.estimatedCostUsd ?? -1) }
    }
}

/// Whether two PAYLOAD strings say the same thing to a reader: the same words,
/// ignoring case, surrounding space and a trailing full stop.
///
/// This composes nothing — it only decides whether a second copy of a string
/// the page already printed is worth printing again. A record page used to
/// print its Task title three times: as the heading, again in the outcome
/// byline (`Agent-reported · <title>`, because a one-section Task's section
/// title IS the title), and again as the Recording ledger's TASK row (whose
/// only objective is the title). Two of those carried no fact (F1).
func restatesPayloadText(_ lhs: String, _ rhs: String?) -> Bool {
    func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
    guard let rhs else { return false }
    let left = normalized(lhs)
    return !left.isEmpty && left == normalized(rhs)
}

// MARK: - Agent outcome summary

/// The agent's outcome summary under the verdict: its source label and the
/// section it came from in a caption, the words in body ink (verbatim, never
/// parsed as markdown), four lines with a disclosure for the rest.
struct AgentOutcomeSummary: View {
    let summary: String
    let label: String
    let sectionTitle: String?
    /// The reading role. The record header passes its ramp's CONSEQUENCE step,
    /// so what the state meant for the work is the most prominent prose on the
    /// page; every other surface keeps body. The clamp is what makes a hero
    /// role safe for a 900-character handoff note — the words are all still
    /// there, one disclosure away.
    var role: WorkFontRole = .body
    var tracking: CGFloat = 0
    @State private var expanded = false

    /// How many lines the summary keeps before its disclosure. A hero-weight
    /// summary is a headline, so it holds fewer.
    private var lineBudget: Int {
        switch role {
        case .titlePage, .titleSection: return 3
        default: return 4
        }
    }

    /// A summary long enough to exceed its line budget at the reading measure.
    private var isLong: Bool {
        let perLine = role == .body ? 80 : 60
        return summary.count > perLine * lineBudget
            || summary.split(separator: "\n", omittingEmptySubsequences: false).count > lineBudget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([label, sectionTitle].compactMap { $0 }.joined(separator: " · "))
                .workFont(.captionSemibold).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: summary)
                .workFont(role).tracking(tracking).foregroundStyle(Theme.ink)
                .lineLimit(expanded ? nil : lineBudget)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isLong {
                Button(expanded ? "Show less" : "Show full summary") { expanded.toggle() }
                    .buttonStyle(QuietButtonStyle(tint: Theme.accent))
                    .workFont(.captionSemibold)
                    .hangingLeading()
                    .accessibilityIdentifier("work.outcome-summary.toggle")
            }
        }
        .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.outcome-summary")
    }
}

// MARK: - Lifecycle marker

/// The deliberate-stop marker beside a different decision word: the reducer's
/// words in the sans state-word style with the handoff glyph — never a chip
/// (a chip reads as a provenance/client tag) and never a decision badge.
struct LifecycleMarker: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Text("↗").accessibilityHidden(true)
            Text(text)
        }
        .workFont(.captionSemibold)
        .foregroundStyle(Theme.muted)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Decision-status legend

/// A small info affordance that opens the decision-word legend. Lives beside
/// every surface that shows decision words (table controls, record title).
/// The evidence-grade rows come from the payload tier table (`tier_legend`)
/// and the coverage definition (`evidence.definition`) when a record carries them.
struct DecisionLegendButton: View {
    /// The vocabulary's status legend (`/v1/tasks` `decision_legend`).
    var legend: DecisionLegendPayload? = nil
    var tierLegend: [ReceiptTierDefinition]? = nil
    var definition: String? = nil
    /// The reducer's scope-term definition, shown once when the record uses it.
    var scopeDefinition: String? = nil
    @State private var shown = false

    var body: some View {
        // Popovers need live interaction; the offscreen renderer draws the
        // trigger as noise, so snapshots omit the control entirely.
        if !SnapshotMode.enabled || SnapshotMode.interactiveFixture {
            IconButton(
                systemName: "info.circle",
                label: "Status legend",
                help: "What each status word means",
                tint: Theme.muted,
                identifier: "work.status-legend"
            ) {
                shown.toggle()
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Space.s) {
                    CapsLabel(text: "Status words")
                    if let legend, !legend.decisions.isEmpty {
                        ForEach(legend.decisions) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                                DecisionBadge(key: entry.key, label: entry.label, compact: true)
                                    .frame(width: 132, alignment: .leading)
                                Text(entry.definition)
                                    .workFont(.caption).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        DisclosureGroup("Status groups") {
                            VStack(alignment: .leading, spacing: Space.s) {
                                ForEach(legend.groups) { group in
                                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                                        Text(group.label).workFont(.captionSemibold).foregroundStyle(Theme.ink)
                                            .frame(width: 132, alignment: .leading)
                                        Text(group.definition)
                                            .workFont(.caption).foregroundStyle(Theme.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(.top, Space.xs)
                        }.workFont(.caption)
                    } else {
                        Text("Status definitions not reported.")
                            .workFont(.caption).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let scopeDefinition = PayloadAbsence.text(scopeDefinition) {
                        Text(scopeDefinition)
                            .workFont(.caption).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("Evidence grades") {
                        VStack(alignment: .leading, spacing: Space.s) {
                            if let rows = tierLegend, !rows.isEmpty {
                                ForEach(rows) { row in
                                    VStack(alignment: .leading, spacing: Space.xs) {
                                        TierBadge(
                                            grade: row.key,
                                            text: PayloadAbsence.text(row.label)
                                                ?? EvidenceTierStyle.forGrade(row.key).label
                                        )
                                        Text(PayloadAbsence.text(row.definition) ?? "Definition not reported.")
                                            .workFont(.caption).foregroundStyle(Theme.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                Text("Evidence tier definitions arrive with a task record.")
                                    .workFont(.caption).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let definition = PayloadAbsence.text(definition) {
                                Text(definition)
                                    .workFont(.caption).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, Space.xs)
                    }.workFont(.caption)
                }
                .padding(Space.l)
                .frame(width: 440)
                // An opaque card surface: card text never shows through (K84).
                .popoverSurface()
            }
        }
    }
}

/// The record header's type ramp (C1). It used to put the computed PROOF
/// CLAUSE one step above the task title, so the largest string on the page was
/// the grading system's verdict on the work — `Not gradeable (only step
/// stopped: handed off)` set over a Task that had, in fact, shipped and tested
/// a function. The ramp now reads work-first: the task title takes the top
/// step, the agent's own outcome sentence — the CONSEQUENCE — takes the next,
/// and the proof clause is a tile figure like every other (`RecordSummary‑
/// Presentation`), never the loudest thing on the record.
struct VerdictHeroTypeRamp {
    let title: WorkFontRole
    /// What the state MEANT for the work, one ramp step under the title.
    let consequence: WorkFontRole
    let titleTracking: CGFloat
    let consequenceTracking: CGFloat

    init(dense: Bool) {
        if dense {
            title = .titleSection
            consequence = .titleCard
            titleTracking = Type.titleSectionTracking
            consequenceTracking = 0
        } else {
            title = .titlePage
            consequence = .titleSection
            titleTracking = Type.titlePageTracking
            consequenceTracking = Type.titleSectionTracking
        }
    }
}

struct WorkPane: View {
    @Environment(DashboardStore.self) var dashboard
    @Environment(AppSelection.self) var selection
    @Environment(\.savedWorkReconnect) private var reconnectSavedWork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var unresolvedSessionId: String?
    @State private var timelineFocused = false

    init(timelineFocused: Bool = false) {
        _timelineFocused = State(initialValue: timelineFocused)
    }

    private var selectionKey: String {
        if let taskId = selection.taskId { return "task:\(taskId)" }
        if let sessionId = selection.sessionId { return "session:\(sessionId)" }
        return "list"
    }

    private var phaseKey: WorkRecordPhaseKey {
        let refreshError = workReceiptRefreshError(
            selectedTaskId: selection.taskId,
            errorTaskId: dashboard.receiptErrorTaskId,
            error: dashboard.receiptError
        )
        return workRecordPhaseKey(
            selectedTaskId: selection.taskId,
            sessionId: selection.sessionId,
            unresolvedSessionId: unresolvedSessionId,
            receiptTaskId: dashboard.receipt?.taskId,
            errorPresent: refreshError != nil
        )
    }

    private var listTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: -12)),
            removal: .opacity.combined(with: .offset(x: -12))
        )
    }

    private var detailTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 12)),
            removal: .opacity.combined(with: .offset(x: 12))
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let mode = workLayoutMode(
                for: proxy.size.width,
                dynamicTypeSize: dynamicTypeSize,
                hasSelection: selection.taskId != nil || unresolvedSessionId != nil
            )
            Group {
                switch timelineFocused && selection.taskId != nil ? .pushDetail : mode {
                case .table:
                    WorkTablePage(
                        browse: selection.workBrowse,
                        narrow: proxy.size.width < 1_080,
                        paneWidth: proxy.size.width
                    )
                        .transition(listTransition)
                case .split:
                    splitLayout(size: proxy.size)
                        .transition(detailTransition)
                case .pushDetail:
                    recordDetail(autoFocusEntry: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(detailTransition)
                }
            }
            // Density follows width — the same 1080 threshold as the layout
            // mode. A breakpoint rearranges facts; it never removes them.
            .environment(\.workCompactViewport, proxy.size.width < 1_080)
        }
        .animation(
            reduceMotion ? Motion.reducedCrossfade : Motion.detailNavigation,
            value: selectionKey
        )
        .task(id: selectionKey) {
            // The fixture renderer injects the exact Work state under review.
            // Starting a live fetch here would immediately clear an injected
            // error and collapse error/loading snapshots into the same frame.
            guard !SnapshotMode.enabled else { return }
            await resolveSelection()
        }
        .task(id: selectionKey) {
            guard !SnapshotMode.enabled, !dashboard.isOfflineSnapshot, let taskId = selection.taskId else { return }
            // Refresh only this task while it is visible. The store rejects
            // obsolete responses when navigation changes during a request.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled, selection.taskId == taskId else { return }
                await dashboard.fetchReceipt(taskId: taskId)
            }
        }
        .task(id: selection.workBrowse.group) {
            guard !SnapshotMode.enabled, selection.workBrowse.group == .attention else { return }
            await dashboard.fetchAttention()
        }
    }

    @ViewBuilder
    private func splitLayout(size: CGSize) -> some View {
        // HSplitView is the native resizable live control, but AppKit-backed
        // split views become a warning placeholder in ImageRenderer. The fixed
        // SwiftUI sibling uses the same ideal width for deterministic review.
        Group {
            if SnapshotMode.enabled && !SnapshotMode.interactiveFixture {
                HStack(alignment: .top, spacing: 0) {
                    WorkMasterList(browse: selection.workBrowse)
                        .frame(width: 320)
                    Rectangle().fill(Theme.rule).frame(width: 1)
                    recordDetail(autoFocusEntry: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                HSplitView {
                    WorkMasterList(browse: selection.workBrowse)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                    recordDetail(autoFocusEntry: false)
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }

    /// Keep list navigation, direct Task links, and menu-bar session links on
    /// one lifecycle. The task id is part of `.task(id:)`, so changing rows
    /// cancels an obsolete Receipt request before starting the next one.
    private func resolveSelection() async {
        unresolvedSessionId = nil
        if selectionKey == "list" || dashboard.receiptTasks.isEmpty {
            await dashboard.fetchReceipts()
        }
        if let taskId = selection.taskId {
            await dashboard.fetchReceipt(taskId: taskId)
            return
        }
        guard let sessionId = selection.sessionId else { return }
        switch workSessionResolution(for: sessionId, in: dashboard.receiptTasks) {
        case .task(let taskId):
            selection.taskId = taskId
            selection.sessionId = nil
        case .unresolved(let sessionId):
            // Compact Task summaries intentionally carry only the primary root.
            // Keep a continuation/subagent selection intact and explain the
            // limitation instead of silently replacing it with an empty detail.
            unresolvedSessionId = sessionId
        }
    }

    @ViewBuilder
    private func recordDetail(autoFocusEntry: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let receipt = dashboard.receipt, receipt.taskId == selection.taskId {
                    WorkRecordPage(
                        receipt: receipt,
                        summary: dashboard.receiptTasks.first { $0.taskId == receipt.taskId },
                        refreshError: workReceiptRefreshError(
                            selectedTaskId: selection.taskId,
                            errorTaskId: dashboard.receiptErrorTaskId,
                            error: dashboard.receiptError
                        ),
                        isRefreshing: dashboard.receiptLoadingTaskId == receipt.taskId,
                        autoFocusEntry: autoFocusEntry,
                        timelineFocused: timelineFocused,
                        onToggleTimelineFocus: { timelineFocused.toggle() }
                    )
                } else if let taskId = selection.taskId,
                          let error = workReceiptRefreshError(
                              selectedTaskId: taskId,
                              errorTaskId: dashboard.receiptErrorTaskId,
                              error: dashboard.receiptError
                          ) {
                    WorkRecordPlaceholder(
                        title: "Receipt unavailable",
                        message: error,
                        symbol: "exclamationmark.triangle",
                        retryTitle: dashboard.isOfflineSnapshot
                            ? (reconnectSavedWork == nil ? nil : "Back to recovery")
                            : (dashboard.receiptLoadingTaskId == taskId ? nil : "Retry"),
                        showsProgress: dashboard.receiptLoadingTaskId == taskId,
                        autoFocusEntry: autoFocusEntry
                    ) {
                        if dashboard.isOfflineSnapshot { reconnectSavedWork?() }
                        else { Task { await dashboard.fetchReceipt(taskId: taskId) } }
                    }
                } else if let unresolvedSessionId, selection.sessionId == unresolvedSessionId {
                    WorkRecordPlaceholder(
                        title: "Task link unavailable",
                        message: "This active session is not identified in the task summary. Select its Task from the collection to inspect the full receipt.",
                        symbol: "arrow.triangle.branch",
                        autoFocusEntry: autoFocusEntry
                    )
                    .accessibilityIdentifier("work.unresolved-session")
                } else if selection.taskId != nil {
                    WorkRecordPlaceholder(
                        title: "Loading receipt",
                        message: "Fetching the latest evidence and check results…",
                        symbol: "arrow.triangle.2.circlepath",
                        showsProgress: true,
                        autoFocusEntry: autoFocusEntry
                    )
                } else {
                    Color.clear
                }
            }
            .id(phaseKey)
            .transition(.opacity)
        }
        .animation(
            reduceMotion ? Motion.reducedCrossfade : Motion.phaseCrossfade,
            value: phaseKey
        )
    }
}

/// Loading and failure states keep the record shell navigable. A failed or slow
/// request must not trap compact-window and keyboard users on a blank surface.
private struct WorkRecordPlaceholder: View {
    @Environment(AppSelection.self) var selection
    @Environment(DashboardStore.self) var dashboard
    let title: String
    let message: String
    let symbol: String
    var retryTitle: String?
    var showsProgress = false
    var autoFocusEntry = false
    var retry: (() -> Void)?
    @FocusState private var backFocused: Bool
    @AccessibilityFocusState private var backAccessibilityFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton

            Card {
                VStack(spacing: Space.m) {
                    if showsProgress && !SnapshotMode.enabled {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(showsProgress ? Theme.muted : Theme.amber)
                            .accessibilityHidden(true)
                    }
                    Text(title).workFont(.titleCard).foregroundStyle(Theme.ink)
                    Text(message)
                        .workFont(.body).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: min(420, Metrics.readingMeasure))
                    if let retryTitle, let retry {
                        Button(retryTitle, action: retry)
                            .buttonStyle(QuietButtonStyle(tint: Theme.accent))
                            .accessibilityIdentifier("work.placeholder.retry")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, Space.xl)
            Spacer(minLength: 0)
        }
        .padding(Space.gutter)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            guard autoFocusEntry, !SnapshotMode.enabled else { return }
            DispatchQueue.main.async {
                backFocused = true
                backAccessibilityFocused = true
            }
        }
    }

    @ViewBuilder
    private var backButton: some View {
        // ImageRenderer blanks controls carrying AccessibilityFocusState.
        // The live path retains it; snapshots render the same visible button.
        if SnapshotMode.enabled {
            backButtonBase
        } else {
            backButtonBase.accessibilityFocused($backAccessibilityFocused)
        }
    }

    private var backButtonBase: some View {
        Button {
            selection.workBrowse.prepareReturnFocus(
                from: selection.taskId,
                in: dashboard.receiptTasks,
                attention: dashboard.attention
            )
            selection.taskId = nil
            selection.sessionId = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .workFont(.icon)
                    .accessibilityHidden(true)
                Text("All tasks").workFont(.captionSemibold)
            }
            .foregroundStyle(Theme.accent)
            .minimumHitTarget(alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(horizontalPadding: 6, verticalPadding: 3))
        .focused($backFocused)
        .keyboardShortcut(.cancelAction)
        .help("Back to all tasks (Esc)")
        .accessibilityLabel("All tasks")
        .accessibilityIdentifier("work.placeholder.back")
    }
}

// MARK: - Work receipts table

struct WorkTaskPresentation {
    let groupCounts: [WorkGroup: Int]
    let visibleTasks: [ReceiptSummary]

    init(
        tasks: [ReceiptSummary],
        attention: V1AttentionPayload? = nil,
        attentionTotal: Int? = nil,
        group: WorkGroup?,
        query: String,
        sort: WorkSort
    ) {
        var counts = Dictionary(grouping: tasks, by: WorkGroup.forTask).mapValues(\.count)
        // Attention is complete across the store and can exceed the loaded
        // receipts page; other lifecycle counts still describe that page. The
        // total comes from whichever attention page is loaded (K87); the queue
        // ITEMS below come only from the queue page the Work pane asked for.
        if let total = attentionTotal ?? attention?.total { counts[.attention] = total }
        groupCounts = counts

        // The endpoint has already classified and operationally ordered a
        // bounded queue across every visible Task. Do not re-derive it from
        // the latest receipts page.
        let sourceTasks = group == .attention ? attention?.items ?? [] : tasks
        visibleTasks = visibleWorkReceipts(
            sourceTasks,
            query: query,
            group: group == .attention ? nil : group,
            sort: sort
        )
    }
}

private struct WorkTablePage: View {
    @Environment(DashboardStore.self) var dashboard
    @Environment(AppSelection.self) var selection
    @ObservedObject var browse: WorkBrowseState
    /// Below the 1080 layout threshold the table folds Client into the title
    /// meta line and stacks Cost over Updated (same facts, fewer columns).
    var narrow = false
    /// The pane's proposed width; the table allocates its columns from it.
    var paneWidth: CGFloat? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var captionScaledSize: CGFloat = 12
    @FocusState private var searchFocused: Bool
    /// The table is ONE keyboard stop that owns a roving row, the way a native
    /// list behaves. Rows stay Buttons (pointer and VoiceOver keep their press
    /// action); Tab never has to walk 66 of them (K77).
    @FocusState private var tableFocused: Bool
    @State private var focusedTaskId: String?
    @AccessibilityFocusState private var searchAccessibilityFocused: Bool
    @AccessibilityFocusState private var accessibilityFocusedTaskId: String?

    var body: some View {
        let presentation = WorkTaskPresentation(
            tasks: dashboard.receiptTasks,
            attention: dashboard.attention,
            attentionTotal: dashboard.attentionTotal,
            group: browse.group,
            query: browse.query,
            sort: browse.sort
        )
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                ScrollBox {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        tabs(
                            groupCounts: presentation.groupCounts,
                            visibleCount: presentation.visibleTasks.count
                        )
                        .padding(.top, Space.xl)
                        filterRow.padding(.top, Space.m)
                        // The banner is for RETAINED data: it says the rows below
                        // are the last loaded set. With no rows the card states
                        // the same failure itself, so showing both said one thing
                        // twice (K53).
                        let showsBanner = browse.group != .attention
                            && dashboard.receiptListError != nil
                            && !presentation.visibleTasks.isEmpty
                        if showsBanner, let error = dashboard.receiptListError {
                            listStatusBanner(error).padding(.top, Space.m)
                        }
                        tableCard(visibleTasks: presentation.visibleTasks, scrollProxy: scrollProxy)
                            .padding(.top, showsBanner ? Space.m : Space.l)
                    }
                    .padding(Space.gutter)
                    .pageFrame()
                }
                footerBar(visibleTasks: presentation.visibleTasks)
            }
            // ⌘F is the standard way into this pane's search field (K114).
            .focusedSceneValue(\.focusSearch, FocusSearchAction {
                searchFocused = true
                searchAccessibilityFocused = true
            })
            .onAppear {
                restoreReturnFocus(visibleTasks: presentation.visibleTasks, scrollProxy: scrollProxy)
            }
            .onChange(of: browse.query) {
                clearInvalidPendingFocus(visibleTasks: presentation.visibleTasks)
            }
            .onChange(of: browse.group) {
                clearInvalidPendingFocus(visibleTasks: presentation.visibleTasks)
            }
        }
    }

    private func restoreReturnFocus(
        visibleTasks: [ReceiptSummary],
        scrollProxy: ScrollViewProxy
    ) {
        guard !SnapshotMode.enabled else { return }
        if let taskId = browse.pendingFocusRestorationTaskId,
           visibleTasks.contains(where: { $0.taskId == taskId }) {
            browse.pendingFocusRestorationTaskId = nil
            scrollProxy.scrollTo(taskId, anchor: .center)
            DispatchQueue.main.async {
                // Returning from a record lands ON the table, with its roving
                // focus back on the row just left — a visible, ringed target
                // instead of the window (K116).
                focusedTaskId = taskId
                tableFocused = true
                accessibilityFocusedTaskId = taskId
            }
            return
        }
        if browse.shouldFocusSearchOnReturn || browse.pendingFocusRestorationTaskId != nil {
            browse.pendingFocusRestorationTaskId = nil
            browse.shouldFocusSearchOnReturn = false
            DispatchQueue.main.async {
                searchFocused = true
                searchAccessibilityFocused = true
            }
        }
    }

    private func clearInvalidPendingFocus(visibleTasks: [ReceiptSummary]) {
        guard let taskId = browse.pendingFocusRestorationTaskId,
              !visibleTasks.contains(where: { $0.taskId == taskId }) else { return }
        browse.pendingFocusRestorationTaskId = nil
    }

    private func moveTableFocus(
        _ direction: MoveCommandDirection,
        visibleTasks: [ReceiptSummary],
        scrollProxy: ScrollViewProxy
    ) {
        guard direction == .up || direction == .down, !visibleTasks.isEmpty else { return }
        let current = visibleTasks.firstIndex { $0.taskId == focusedTaskId }
        let nextIndex: Int
        switch direction {
        case .up: nextIndex = max(0, (current ?? 1) - 1)
        case .down: nextIndex = min(visibleTasks.count - 1, (current ?? -1) + 1)
        default: return
        }
        let taskId = visibleTasks[nextIndex].taskId
        focusedTaskId = taskId
        withAnimation(reduceMotion ? nil : Motion.hover) {
            scrollProxy.scrollTo(taskId, anchor: .center)
        }
    }

    /// The Work pane's ONE name for each of its states. The tab strip, the
    /// search field and the footer all call the object a "task", so these do
    /// too — the pane used to mix "receipts" and "tasks" inside one screen.
    static let taskListUnavailableTitle = "Task list unavailable"
    static let taskListUnavailableCause = "The recorder didn't return tasks."
    static let noTasksRecordedTitle = "No tasks recorded yet"
    static let retryLabel = "Retry"

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Work")
                .workFont(.titlePage).tracking(Type.titlePageTracking)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func tabs(
        groupCounts: [WorkGroup: Int],
        visibleCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                // Type size changes arrangement, never the set of facts: the
                // picker items keep every per-status count the tabs carry.
                WrappingRowLayout(horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
                    Text("Lifecycle").workFont(.caption).foregroundStyle(Theme.muted)
                    AppMenuPicker(
                        title: "Lifecycle",
                        selection: $browse.group,
                        options: lifecycleOptions(groupCounts: groupCounts),
                        accessibilityIdentifier: "work.table.status"
                    )
                    Text("\(visibleCount) shown")
                        .workFont(.dataSmall).foregroundStyle(Theme.muted)
                    if let note = lifecycleCountsNote {
                        Text(note).workFont(.dataSmall).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.bottom, Space.s)
            } else {
                // Tabs hug their labels; Space.xl is the only gap between them.
                HStack(spacing: Space.xl) {
                    tabButton(nil, label: allTabLabel, count: loadedTabCount)
                    ForEach(WorkGroup.allCases) { candidate in
                        let count = tabCount(candidate, groupCounts: groupCounts)
                        // "Other" appears only for an unmapped decision key.
                        if candidate != .other || (count ?? 0) > 0 {
                            tabButton(candidate, label: candidate.label(in: dashboard.decisionLegend), count: count)
                        }
                    }
                    // The absence is named ONCE for the strip rather than on
                    // every tab: seven "not loaded" labels overran the row and
                    // read as "Loaded not loaded" (K54).
                    if let note = lifecycleCountsNote {
                        Text(note)
                            .workFont(.dataSmall).foregroundStyle(Theme.muted)
                            .padding(.bottom, 10)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var receiptPageIsLoaded: Bool {
        workReceiptPageIsLoaded(
            loadedCount: dashboard.receiptTasks.count,
            isLoading: dashboard.isLoadingReceipts,
            error: dashboard.receiptListError
        )
    }

    /// The tab count for one lifecycle group. Attention is complete across
    /// the store and can exceed Loaded; other counts describe that page, and
    /// are absent until it loads.
    private func tabCount(_ candidate: WorkGroup, groupCounts: [WorkGroup: Int]) -> Int? {
        if candidate == .attention { return dashboard.attentionTotal }
        guard receiptPageIsLoaded else { return nil }
        return groupCounts[candidate] ?? 0
    }

    /// The Loaded/All tab's own count: the size of the loaded page, or the
    /// same named absence while there is no page.
    private var loadedTabCount: Int? {
        receiptPageIsLoaded ? dashboard.receiptTasks.count : nil
    }

    /// What the strip says instead of per-tab numbers while no receipts page
    /// has loaded. Attention keeps its own live total: it comes from its own
    /// complete projection, not from this page (K54).
    private var lifecycleCountsNote: String? {
        receiptPageIsLoaded ? nil : "lifecycle counts not loaded"
    }

    private func tabCountText(_ count: Int?) -> String {
        count.map(String.init) ?? "not loaded"
    }

    private var allTabLabel: String {
        let partialOrUnknown = workReceiptCollectionIsPartial(
            loaded: dashboard.receiptTasks.count,
            total: dashboard.totalReceiptTasks,
            truncated: dashboard.receiptTasksTruncated
        ) || dashboard.totalReceiptTasks == nil
        return partialOrUnknown ? "Loaded" : "All"
    }

    private func lifecycleOptions(groupCounts: [WorkGroup: Int]) -> [(WorkGroup?, String)] {
        // While no page has loaded there are no per-status counts to print:
        // the row's note names that once, so an option is its label alone
        // rather than "Verified (not loaded)" seven times (K54).
        func option(_ label: String, _ count: Int?, showsCount: Bool) -> String {
            showsCount ? "\(label) (\(tabCountText(count)))" : label
        }
        var options: [(WorkGroup?, String)] = [
            (nil, option(allTabLabel, loadedTabCount, showsCount: receiptPageIsLoaded))
        ]
        for candidate in WorkGroup.allCases {
            let count = tabCount(candidate, groupCounts: groupCounts)
            if candidate != .other || (count ?? 0) > 0 {
                options.append((
                    candidate,
                    option(
                        candidate.label(in: dashboard.decisionLegend),
                        count,
                        showsCount: receiptPageIsLoaded || candidate == .attention
                    )
                ))
            }
        }
        return options
    }

    private func tabButton(_ candidate: WorkGroup?, label: String, count: Int?) -> some View {
        let active = browse.group == candidate
        // Attention is the one tab whose count comes from its own complete
        // projection, so it keeps its own named absence; the rest fall under
        // the strip's single note while no page has loaded.
        let showsCount = count != nil || candidate == .attention
        return Button {
            browse.group = candidate
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .workFont(size: 13, weight: active ? .semibold : .medium, relativeTo: .body)
                    .foregroundStyle(active ? Theme.accent : Theme.ink)
                if showsCount {
                    Text(tabCountText(count))
                        .workFont(.dataSmall)
                        .foregroundStyle(candidate == .attention && (count ?? 0) > 0 ? Theme.coral : Theme.muted)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 10)
            // The underline rides on the label, so a tab never claims more
            // width than its own words.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? Theme.accent : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("work.tab.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private var filterRow: some View {
        HStack(spacing: Space.m) {
            // The shared app-chrome field (K15). No fixed height: a scaled
            // minimum lets large text reflow, and the width grows only at
            // accessibility sizes.
            AppTextField(
                placeholder: "Search tasks",
                text: $browse.query,
                systemImage: "magnifyingglass",
                focus: $searchFocused,
                accessibilityFocus: $searchAccessibilityFocused,
                accessibilityIdentifier: "work.table.search"
            )
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 420 : 300, alignment: .leading)
            // Down from the search field enters the results, as a native
            // search-and-list pairing does (K77). Return is left alone: it
            // would open a row the reviewer never chose.
            .onKeyPress(.downArrow) {
                guard searchFocused else { return .ignored }
                tableFocused = true
                return .handled
            }
            Text("Sort").workFont(.caption).foregroundStyle(Theme.muted)
            AppMenuPicker(
                title: "Sort",
                selection: $browse.sort,
                options: WorkSort.allCases.map { ($0, $0.rawValue) },
                accessibilityIdentifier: "work.table.sort"
            )
            DecisionLegendButton(
                legend: dashboard.decisionLegend,
                tierLegend: dashboard.receipt?.axes.evidenceStrength.tierLegend,
                definition: dashboard.receipt?.axes.evidenceStrength.definition
            )
            Spacer()
        }
    }

    private func tableCard(
        visibleTasks: [ReceiptSummary],
        scrollProxy: ScrollViewProxy
    ) -> some View {
        Card(padding: 0) {
            let columns = tableColumns(visibleTasks: visibleTasks)
            VStack(spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize {
                    columnHeader(columns)
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, Space.xl)
                }
                if browse.group != .attention,
                   dashboard.isLoadingReceipts,
                   dashboard.receiptTasks.isEmpty {
                    HStack(spacing: Space.m) {
                        if SnapshotMode.enabled {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Loading receipts").workFont(.rowLabel).foregroundStyle(Theme.ink)
                            Text("Reading the latest recorded work from the local store.")
                                .workFont(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading receipts from the local store")
                } else if let error = visibleError, visibleTasks.isEmpty {
                    // One state template: a true title, a short human cause,
                    // the raw error behind a disclosure, one cobalt action
                    // that names the exact retry (K53).
                    EmptyStateView(
                        title: browse.group == .attention
                            ? "Review queue unavailable"
                            : Self.taskListUnavailableTitle,
                        cause: browse.group == .attention
                            ? "The recorder didn't return the review queue."
                            : Self.taskListUnavailableCause,
                        detailDisclosure: error,
                        action: .init(
                            label: Self.retryLabel,
                            identifier: "work.table.retry",
                            perform: { Task { await dashboard.fetchReceipts() } }
                        ),
                        identifier: "work.table.unavailable"
                    )
                    .padding(Space.xl)
                } else if browse.group == .attention, dashboard.attention == nil {
                    HStack(spacing: Space.m) {
                        if SnapshotMode.enabled {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.small).tint(Theme.muted)
                        }
                        Text("Checking the complete review projection…")
                            .workFont(.body).foregroundStyle(Theme.muted)
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if visibleTasks.isEmpty {
                    let attentionCopy = dashboard.attention.map {
                        WorkAttentionEmptyCopy(payload: $0, query: browse.query)
                    }
                    // ONE noun for this pane's object: the tab, the search
                    // field and the footer all say "tasks", so the empty
                    // state does too (K53).
                    EmptyStateView(
                        title: browse.group == .attention
                            ? attentionCopy?.title ?? "Review status unavailable"
                            : dashboard.receiptTasks.isEmpty
                                ? Self.noTasksRecordedTitle : "No tasks match",
                        cause: browse.group == .attention
                            ? attentionCopy?.detail ?? "Refresh before acting on the review queue."
                            : dashboard.receiptTasks.isEmpty
                                ? "Recorded coding work will appear here when the local store receives it."
                                : filteredEmptyMessage,
                        identifier: "work.table.empty"
                    )
                    .padding(Space.xl)
                } else {
                    // Offscreen full-content renders cap the rows and name the
                    // overflow; the live app scrolls the full set.
                    let rows = SnapshotMode.enabled ? Array(visibleTasks.prefix(9)) : visibleTasks
                    ScrollContentStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, task in
                            if index > 0 {
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                                    .padding(.horizontal, Space.xl)
                            }
                            if SnapshotMode.enabled {
                                tableRow(task, columns: columns).id(task.taskId)
                            } else {
                                tableRow(task, columns: columns)
                                    .id(task.taskId)
                                    .accessibilityFocused(
                                        $accessibilityFocusedTaskId,
                                        equals: task.taskId
                                    )
                            }
                        }
                    }
                    if SnapshotMode.enabled, visibleTasks.count > rows.count {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                            .padding(.horizontal, Space.xl)
                        Text("… \(visibleTasks.count - rows.count) more receipts (snapshot preview)")
                            .workFont(.dataSmall).foregroundStyle(Theme.muted)
                            .padding(Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        // ONE keyboard stop for the whole table (K77). With macOS keyboard
        // navigation off — the default — plain Buttons are not in the key
        // loop, so before this the arrow-key code below could never run and
        // there was no keyboard path from the search field into the results.
        .focusable(!visibleTasks.isEmpty)
        .focused($tableFocused)
        // The app draws its own ring below, at the design system's weight.
        .focusEffectDisabled()
        .focusRing(tableFocused)
        .onMoveCommand {
            moveTableFocus($0, visibleTasks: visibleTasks, scrollProxy: scrollProxy)
        }
        .onKeyPress(.return) { openFocusedRow(visibleTasks: visibleTasks) }
        .onKeyPress(.space) { openFocusedRow(visibleTasks: visibleTasks) }
        .onChange(of: tableFocused) { _, focused in
            // Entering the table lands on a row, so the first arrow key moves
            // from somewhere visible.
            guard focused, focusedTaskId == nil || !visibleTasks.contains(where: { $0.taskId == focusedTaskId }) else { return }
            focusedTaskId = visibleTasks.first?.taskId
        }
        // A container id must not become every child's id: `.contain` keeps
        // the table one group and leaves headers and rows their own (K123).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.table")
    }

    /// Open the row the table's roving focus is on (Return or Space), the
    /// same action a click on that row performs.
    private func openFocusedRow(visibleTasks: [ReceiptSummary]) -> KeyPress.Result {
        guard tableFocused,
              let taskId = focusedTaskId ?? visibleTasks.first?.taskId,
              visibleTasks.contains(where: { $0.taskId == taskId }) else { return .ignored }
        selection.sessionId = nil
        selection.taskId = taskId
        return .handled
    }

    @ViewBuilder
    private func tableRow(_ task: ReceiptSummary, columns: WorkTableColumns) -> some View {
        let roving = tableFocused && focusedTaskId == task.taskId
        if dynamicTypeSize.isAccessibilitySize {
            WorkAccessibleTableRow(
                task: task, listLabels: dashboard.receiptFieldLabels, isRovingRow: roving
            ) {
                selection.sessionId = nil
                selection.taskId = task.taskId
            }
        } else {
            WorkTableRow(
                task: task, columns: columns,
                listLabels: dashboard.receiptFieldLabels, isRovingRow: roving
            ) {
                selection.sessionId = nil
                selection.taskId = task.taskId
            }
        }
    }

    /// The caption data face's point size at the current reading size (the
    /// same resolution `workFont(.dataSmall)` applies).
    private var dataFontSize: CGFloat {
        if dynamicTypeSize == .medium || dynamicTypeSize == .large { return 12 }
        return max(12, WorkTypeScale.resolved(
            base: 12,
            systemScaled: captionScaledSize,
            dynamicTypeSize: dynamicTypeSize
        ))
    }

    /// Fixed data columns sized from the longest string the rows will print
    /// (and the header label) at the data face, so no cell ever wraps.
    private func tableColumns(visibleTasks: [ReceiptSummary]) -> WorkTableColumns {
        let labels = dashboard.receiptFieldLabels
        let rows = (SnapshotMode.enabled ? Array(visibleTasks.prefix(9)) : visibleTasks)
            .map { WorkReceiptRowPresentation(task: $0, listLabels: labels) }
        return WorkTableColumns(
            rows: rows,
            labels: labels ?? rows.first?.fieldLabels ?? ReceiptFieldLabels(),
            fontSize: dataFontSize,
            narrow: narrow,
            rowWidth: paneWidth.map(WorkTableColumns.rowWidth(forPaneWidth:))
        )
    }

    private func listStatusBanner(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            if dashboard.isLoadingReceipts, !SnapshotMode.enabled {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .workFont(.icon).foregroundStyle(Theme.amber)
                    .accessibilityHidden(true)
            }
            // The banner states the CAUSE in words; the raw error rides in
            // the same disclosure the empty states use, so it is copyable
            // without being the message (K53).
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(
                    dashboard.isLoadingReceipts
                        ? "Retrying the task list · showing the last loaded data when available"
                        : dashboard.receiptTasks.isEmpty
                        ? "\(Self.taskListUnavailableTitle) · \(Self.taskListUnavailableCause)"
                        : "Showing the last loaded task list · the refresh failed."
                )
                .workFont(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
                if !dashboard.isLoadingReceipts {
                    DisclosureGroup(EmptyStateView.detailsLabel) {
                        Text(error)
                            .workFont(.caption).foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
                            .padding(.top, Space.xs)
                    }
                    .workFont(.caption).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("work.list.status.details")
                }
            }
            Spacer(minLength: Space.m)
            if !dashboard.isLoadingReceipts {
                Button(Self.retryLabel) { Task { await dashboard.fetchReceipts() } }
                    .buttonStyle(QuietButtonStyle(tint: Theme.accent))
                    .accessibilityIdentifier("work.list.retry")
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Theme.tintAmberOnCanvas, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius)
                .strokeBorder(Theme.rule, lineWidth: Metrics.borderW)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.list.status")
    }

    private func columnHeader(_ columns: WorkTableColumns) -> some View {
        HStack(spacing: Space.l) {
            CapsLabel(text: columns.labels.taskLabel).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            CapsLabel(text: columns.labels.coverageLabel).lineLimit(1)
                .frame(width: columns.evidence, alignment: .leading)
            if !columns.narrow {
                CapsLabel(text: columns.labels.clientLabel).lineLimit(1)
                    .frame(width: WorkTableColumns.clientWidth, alignment: .leading)
            }
            CapsLabel(text: columns.labels.checksLabel).lineLimit(1)
                .frame(width: columns.checks, alignment: .trailing)
            if columns.narrow {
                VStack(alignment: .trailing, spacing: 2) {
                    CapsLabel(text: columns.labels.costLabel).lineLimit(1)
                    CapsLabel(text: columns.labels.updatedLabel).lineLimit(1)
                }
                .frame(width: columns.stacked, alignment: .trailing)
            } else {
                CapsLabel(text: columns.labels.costLabel).lineLimit(1)
                    .frame(width: columns.cost, alignment: .trailing)
                CapsLabel(text: columns.labels.updatedLabel).lineLimit(1)
                    .frame(width: columns.updated, alignment: .trailing)
            }
        }
        .padding(.horizontal, Space.xl)
        .frame(minHeight: Metrics.rowHeader)
        // The header row is one named group: its labels are column names, not
        // stray text between rows, and they stop inheriting the table's id.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Column headers")
        .accessibilityIdentifier("work.table.columns")
    }

    /// The count, pinned under the scrolling list.
    ///
    /// At the minimum window this page is taller than the viewport, so the
    /// list scrolls. Inside the scroll region the count scrolled away with it:
    /// a reviewer at the minimum size saw a row cut by the window edge and no
    /// statement of how many tasks there are (K57). Pinned, the count is
    /// readable at every window size, and its hairline is the edge the rows
    /// pass under — the honest affordance that the list continues.
    private func footerBar(visibleTasks: [ReceiptSummary]) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: Metrics.borderW)
            footer(visibleTasks: visibleTasks)
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.m)
                .pageFrame()
        }
        .background(Theme.canvas)
    }

    private func footer(visibleTasks: [ReceiptSummary]) -> some View {
        HStack(spacing: Space.m) {
            Text(footerText(visibleTasks: visibleTasks))
                .workFont(.dataSmall).foregroundStyle(Theme.muted)
            if browse.group == .attention, let error = dashboard.attentionError {
                Text(error)
                    .workFont(.dataSmall)
                    .foregroundStyle(Theme.coral)
                    .lineLimit(1)
            }
            Spacer()
            if browse.group == .attention, dashboard.attention?.truncated == true {
                Button(dashboard.isLoadingMoreAttention ? "Loading…" : "Load more") {
                    Task { await dashboard.fetchMoreAttention() }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(dashboard.isLoadingMoreAttention)
                .accessibilityIdentifier("work.attention.load-more")
            }
        }
    }

    private var visibleError: String? {
        browse.group == .attention ? dashboard.attentionError : dashboard.receiptListError
    }

    private func footerText(visibleTasks: [ReceiptSummary]) -> String {
        let order = browse.sort.footerText(queue: dashboard.attentionQueue)
        if browse.group == .attention, let attention = dashboard.attention {
            let scope = attention.truncated ? "bounded operational queue" : "complete queue"
            let count = PayloadAbsence.text(attention.queue?.countText) ?? "\(attention.total) in queue"
            return "\(visibleTasks.count) of \(count) · \(scope) · \(order)"
        }
        return workBrowseCountText(
            visible: visibleTasks.count,
            loaded: dashboard.receiptTasks.count,
            total: dashboard.totalReceiptTasks,
            truncated: dashboard.receiptTasksTruncated,
            pageIsLoaded: receiptPageIsLoaded
        ) + " · \(order)"
    }

    private var filteredEmptyMessage: String {
        if let total = dashboard.totalReceiptTasks,
           workReceiptCollectionIsPartial(
               loaded: dashboard.receiptTasks.count,
               total: total,
               truncated: dashboard.receiptTasksTruncated
           ) {
            return "No loaded receipts match. Search covers the latest \(dashboard.receiptTasks.count) of \(total) receipts."
        }
        if dashboard.totalReceiptTasks == nil || dashboard.receiptTasksTruncated == true {
            return "No loaded receipts match. The store did not report a complete total, so more receipts may exist."
        }
        return "Adjust the lifecycle tab or the filter to broaden the result."
    }


}

/// The width, in points, of `text` set in the Work data face (mono) at `size`.
func workDataTextWidth(_ text: String, size: CGFloat, bold: Bool = false, tracking: CGFloat = 0) -> CGFloat {
    var font: NSFont = Face.mono.flatMap { NSFont(name: $0, size: size) }
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    if bold, Face.mono != nil {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if tracking != 0 { attributes[.kern] = tracking }
    return ceil((text as NSString).size(withAttributes: attributes).width)
}

/// The receipts table's data columns. Task is the flexible, dominant column:
/// each data column is sized from the strings its rows print (and its header
/// label) at the data face. When the one-line widths would leave the task
/// column below `taskMinimum`, the widest columns switch — in order — to their
/// wrapped width (a tally stacks at its " · " segments; a named absence wraps
/// onto two lines at a word break), so titles keep the room they need and no
/// cell is ever truncated.
struct WorkTableColumns {
    static let clientWidth: CGFloat = 124
    /// Upper bounds keep one pathological string from starving the title.
    static let dataColumnCap: CGFloat = 260
    static let pipAndGap: CGFloat = Metrics.pipR * 2 + 7
    static let slack: CGFloat = 4
    /// Gap between cells (the row HStack spacing).
    static let cellSpacing: CGFloat = Space.l
    /// The task column never gives up more than this to one-line data cells.
    static let taskMinimumWidth: CGFloat = 320
    static let taskMinimumShare: CGFloat = 0.42

    let labels: ReceiptFieldLabels
    let narrow: Bool
    let evidence: CGFloat
    let checks: CGFloat
    let cost: CGFloat
    let updated: CGFloat
    /// The check tally stacks its " · " segments instead of one line.
    let wrapsChecks: Bool
    /// The cost cell may wrap a named absence onto two lines.
    let wrapsCost: Bool

    /// Narrow rows stack Cost over Updated in one column.
    var stacked: CGFloat { max(cost, updated) }

    /// The row's content width inside the table card for a pane width: the
    /// page is capped at `Metrics.pageMaxWidth`, inset by the page gutter, and
    /// each row is inset by `Space.xl`.
    static func rowWidth(forPaneWidth width: CGFloat) -> CGFloat {
        min(width, Metrics.pageMaxWidth) - 2 * Space.gutter - 2 * Space.xl
    }

    /// The segments a check tally stacks into when its column wraps.
    static func checkSegments(_ text: String) -> [String] {
        text.components(separatedBy: " · ").filter { !$0.isEmpty }
    }

    init(
        rows: [WorkReceiptRowPresentation],
        labels: ReceiptFieldLabels,
        fontSize: CGFloat,
        narrow: Bool,
        rowWidth: CGFloat? = nil
    ) {
        self.labels = labels
        self.narrow = narrow
        func width(_ text: String) -> CGFloat { workDataTextWidth(text, size: fontSize) }
        func header(_ text: String) -> CGFloat {
            workDataTextWidth(text.uppercased(), size: fontSize, bold: true, tracking: Type.labelCapsTracking)
        }
        func widest(_ strings: [String]) -> CGFloat {
            strings.map(width).max() ?? 0
        }
        func clamp(_ value: CGFloat) -> CGFloat {
            min(Self.dataColumnCap, value + Self.slack)
        }
        /// The narrowest width that sets `text` on at most two lines, breaking
        /// only at spaces (greedy wrapping at this width finds that split).
        func twoLineWidth(_ text: String) -> CGFloat {
            let words = text.split(separator: " ").map(String.init)
            guard words.count > 1 else { return width(text) }
            return (1..<words.count).map { split in
                max(
                    width(words[..<split].joined(separator: " ")),
                    width(words[split...].joined(separator: " "))
                )
            }.min() ?? width(text)
        }

        evidence = clamp(max(
            header(labels.coverageLabel),
            Self.pipAndGap + widest(rows.map(\.coverageText))
        ))
        let checksOneLine = clamp(max(
            header(labels.checksLabel),
            widest(rows.flatMap { row in
                row.checkRunsAreInconsistent
                    ? [row.checkRunsValue, row.checkRunsQualifier]
                    : [row.compactCheckRunsText]
            })
        ))
        let checksWrapped = clamp(max(
            header(labels.checksLabel),
            widest(rows.flatMap { row in
                row.checkRunsAreInconsistent
                    ? [row.checkRunsValue, row.checkRunsQualifier]
                    : Self.checkSegments(row.compactCheckRunsText)
            })
        ))
        let costOneLine = clamp(max(header(labels.costLabel), widest(rows.map(\.costDisplayText))))
        let costWrapped = clamp(max(
            header(labels.costLabel),
            rows.map { row in
                row.costIsAbsent ? twoLineWidth(row.costDisplayText) : width(row.costDisplayText)
            }.max() ?? 0
        ))
        updated = clamp(max(header(labels.updatedLabel), widest(rows.map(\.updatedText))))

        var useWrappedChecks = false
        var useWrappedCost = false
        if let rowWidth {
            let taskMinimum = max(Self.taskMinimumWidth, rowWidth * Self.taskMinimumShare)
            let evidence = self.evidence
            let updated = self.updated
            func taskWidth(checks: CGFloat, cost: CGFloat) -> CGFloat {
                let cells: [CGFloat] = narrow
                    ? [evidence, checks, max(cost, updated)]
                    : [evidence, Self.clientWidth, checks, cost, updated]
                return rowWidth - cells.reduce(0, +) - CGFloat(cells.count) * Self.cellSpacing
            }
            if taskWidth(checks: checksOneLine, cost: costOneLine) < taskMinimum {
                useWrappedChecks = checksWrapped < checksOneLine
                if taskWidth(checks: useWrappedChecks ? checksWrapped : checksOneLine, cost: costOneLine) < taskMinimum {
                    useWrappedCost = costWrapped < costOneLine
                }
            }
        }
        wrapsChecks = useWrappedChecks
        wrapsCost = useWrappedCost
        checks = useWrappedChecks ? checksWrapped : checksOneLine
        cost = useWrappedCost ? costWrapped : costOneLine
    }
}

/// One receipts-table row (52pt): task + decision badge (with the attention
/// reason and evidence gap beneath), evidence tier pip and coverage, client
/// chip, checks, cost, and recency.
private struct WorkTableRow: View {
    let task: ReceiptSummary
    let columns: WorkTableColumns
    /// The list's field headers from `/v1/tasks`, so a row names its fields in
    /// the payload's words even before its detail receipt is loaded.
    let listLabels: ReceiptFieldLabels?
    /// The table's roving focus is on this row (the table itself holds the
    /// keyboard focus, K77), so it wears the selection cue at reduced weight.
    let isRovingRow: Bool
    let action: () -> Void

    private var presentation: WorkReceiptRowPresentation { .init(task: task, listLabels: listLabels) }

    var body: some View {
        let presentation = self.presentation
        Button(action: action) {
            // Cells sit on the TITLE's first baseline, not centred on a task
            // cell that may run three lines: a row's coverage, checks and cost
            // read on the line that names the task (K20).
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        // The task's name is how a reviewer tells rows apart,
                        // so it wraps to a second line before it truncates —
                        // the lines beneath it already get two (K20).
                        Text(presentation.title)
                            .workFont(.rowLabel).foregroundStyle(Theme.ink)
                            .lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(presentation.title)
                        DecisionBadge(
                            key: presentation.decisionKey,
                            label: presentation.decisionLabel,
                            compact: true,
                            help: presentation.decisionHelp
                        )
                        // Parallel deliberate-stop marker, only when it adds info the
                        // decision word does not already state.
                        if let marker = presentation.lifecycleMarkerText {
                            LifecycleMarker(text: marker)
                        }
                    }
                    // The standing attention reason is a row fact, not a tooltip.
                    if let reason = presentation.attentionReason, !reason.isEmpty {
                        Text(verbatim: reason)
                            .workFont(.caption).foregroundStyle(presentation.attentionReasonTint)
                            .lineLimit(2)
                    }
                    // What is NOT yet proven, then what the ratio does not
                    // cover — facts no column carries, each on its own line so
                    // the proof label never spans a stop or scope count.
                    if let gap = presentation.gapLine {
                        Text(gap)
                            .workFont(FieldFont.gapLine).foregroundStyle(Theme.muted)
                            .lineLimit(2).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(gap)
                    }
                    if let ledger = presentation.ledgerText {
                        Text(ledger)
                            .workFont(FieldFont.gapLine).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.tail)
                            .help(ledger)
                    }
                    if columns.narrow {
                        Text(presentation.clientText)
                            .workFont(.dataSmall).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                evidenceCell(presentation).frame(width: columns.evidence, alignment: .leading)
                if !columns.narrow {
                    clientCell(presentation).frame(width: WorkTableColumns.clientWidth, alignment: .leading)
                }
                checksCell(presentation).frame(width: columns.checks, alignment: .trailing)
                if columns.narrow {
                    VStack(alignment: .trailing, spacing: 2) {
                        costCell(presentation)
                        updatedCell(presentation)
                    }
                    .frame(width: columns.stacked, alignment: .trailing)
                } else {
                    costCell(presentation).frame(width: columns.cost, alignment: .trailing)
                    updatedCell(presentation).frame(width: columns.updated, alignment: .trailing)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.s)
            .frame(minHeight: Metrics.rowTable)
            .background(isRovingRow ? Theme.selected.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle(
            cornerRadius: 0,
            focusInset: 2
        ))
        .accessibilityIdentifier("work.table.task.\(task.taskId)")
        .accessibilityLabel(presentation.accessibilityLabel)
        .workRowAccessibilityFields(presentation.accessibilityFields)
    }

    /// The reducer's coverage row + the strongest tier's pip shape. The pip is
    /// a ceiling marker (best evidence present), the ratio is the coverage.
    @ViewBuilder
    private func evidenceCell(_ presentation: WorkReceiptRowPresentation) -> some View {
        let gradeable = presentation.evidence.gradeable != false
            && (presentation.evidence.checkableTotal ?? 0) > 0
        HStack(spacing: 7) {
            if gradeable {
                EvidencePip(grade: presentation.strongestTier ?? "unchecked")
            } else {
                // The named "none / not gradeable" tier.
                EvidencePip(grade: nil)
            }
            Text(presentation.coverageText)
                // The face follows the ROLE the reducer gave this reading, not
                // a condition re-derived here: a ratio is a metric, "not
                // gradeable" is a named state and reads as prose (K10).
                .workFont(FieldFont.value(.dataSmall, isMetric: presentation.coverageIsMetric))
                .foregroundStyle(gradeable && !presentation.coverageIsInconsistent ? Theme.ink : Theme.muted)
                .lineLimit(1)
        }
        .modifier(OptionalHelp(text: presentation.coverageQualifier))
    }

    @ViewBuilder
    private func clientCell(_ presentation: WorkReceiptRowPresentation) -> some View {
        if presentation.clientText != "unattributed" {
            // A client slug is an identifier: the one mono chip (K10).
            ProvenanceChip(text: presentation.clientText, mono: true)
        } else {
            // A named absence, not an identifier: prose face (K10).
            Text("unattributed").workFont(FieldFont.value(.dataSmall, isMetric: false))
                .foregroundStyle(Theme.muted)
        }
    }

    /// The reducer's cost figure with its prefix grammar, or its named absence;
    /// the basis rides as help so the figure never stands without it.
    private func costCell(_ presentation: WorkReceiptRowPresentation) -> some View {
        Text(presentation.costDisplayText)
            // A figure is a metric (mono); a named absence is prose (K10).
            .workFont(FieldFont.value(.dataSmall, isMetric: !presentation.costIsAbsent))
            .foregroundStyle(presentation.costIsAbsent ? Theme.muted : Theme.ink)
            .lineLimit(columns.wrapsCost && presentation.costIsAbsent ? 2 : 1)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(OptionalHelp(text: presentation.costBasisLabel))
    }

    private func updatedCell(_ presentation: WorkReceiptRowPresentation) -> some View {
        Text(presentation.updatedText)
            .workFont(.dataSmall).foregroundStyle(Theme.muted)
            .lineLimit(1)
    }

    /// The reducer's check tally, tinted from its `check_runs_state` key —
    /// never by inspecting the copy.
    @ViewBuilder
    private func checksCell(_ presentation: WorkReceiptRowPresentation) -> some View {
        if presentation.checkRunsAreInconsistent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(presentation.checkRunsValue)
                    .workFont(FieldFont.value(.dataSmall, isMetric: presentation.checkRunsIsMetric))
                    .foregroundStyle(Theme.ink)
                Text(presentation.checkRunsQualifier)
                    .workFont(FieldFont.value(.dataSmall, isMetric: presentation.checkRunsIsMetric))
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .help(presentation.checkRunsText)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if columns.wrapsChecks {
            // Stacked at its " · " segments: each segment stays whole.
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(Array(WorkTableColumns.checkSegments(presentation.compactCheckRunsText).enumerated()), id: \.offset) { _, segment in
                    Text(segment).lineLimit(1)
                }
            }
            // The stacked branch used to be unconditionally mono, so a wrapped
            // "no checks recorded" wore the metric face while the same string
            // on one line did not (K10).
            .workFont(FieldFont.value(.dataSmall, isMetric: presentation.checkRunsIsMetric))
            .foregroundStyle(workCheckRunsTint(presentation.checkRunsState))
            // The tooltip rides on the COMBINED cell, never on the stacked
            // segments: a help on the VStack is inherited by every segment
            // Text, and the row then repeated the tally once per segment (K119).
            .accessibilityElement(children: .combine)
            .help(presentation.compactCheckRunsText)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(presentation.compactCheckRunsText)
                // A tally is a metric; "no checks recorded" is an absence (K10).
                .workFont(FieldFont.value(.dataSmall, isMetric: presentation.checkRunsIsMetric))
                .foregroundStyle(workCheckRunsTint(presentation.checkRunsState))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The one tint lookup for a check-runs state key.
func workCheckRunsTint(_ state: String?) -> Color {
    switch state {
    case "failed": return Theme.coral
    case "not_run", "not_reported", "none": return Theme.muted
    default: return Theme.ink
    }
}

/// Accessibility text sizes trade the fixed task table for a complete
/// vertical record summary. No fact disappears — the tier badge and evidence
/// gap included; labels and values wrap without colliding.
private struct WorkAccessibleTableRow: View {
    let task: ReceiptSummary
    /// The list's field headers from `/v1/tasks` — this layout PRINTS them
    /// beside each value, so they must be the payload's words, not the app's.
    let listLabels: ReceiptFieldLabels?
    let isRovingRow: Bool
    let action: () -> Void
    private var presentation: WorkReceiptRowPresentation { .init(task: task, listLabels: listLabels) }

    var body: some View {
        let presentation = self.presentation
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(presentation.title)
                    .workFont(.rowLabel).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                WrappingRowLayout(horizontalSpacing: Space.s, verticalSpacing: Space.xs) {
                    DecisionBadge(
                        key: presentation.decisionKey,
                        label: presentation.decisionLabel,
                        compact: true,
                        help: presentation.decisionHelp
                    )
                    if let tier = presentation.strongestTier, let label = presentation.strongestTierLabel {
                        TierBadge(grade: tier, text: "strongest: \(label)")
                    }
                }
                if let reason = presentation.attentionReason, !reason.isEmpty {
                    Text(verbatim: reason).workFont(.caption).foregroundStyle(presentation.attentionReasonTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let gap = presentation.gapLine {
                    Text(gap).workFont(FieldFont.gapLine).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ledger = presentation.ledgerText {
                    Text(ledger).workFont(FieldFont.gapLine).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                labelledValue(presentation.fieldLabels.coverageLabel, presentation.coverageText)
                labelledValue(presentation.fieldLabels.checksLabel, presentation.checkRunsText)
                labelledValue(presentation.fieldLabels.clientLabel, presentation.clientText)
                labelledValue(presentation.fieldLabels.costLabel, presentation.costText, absent: presentation.costIsAbsent)
                labelledValue(presentation.fieldLabels.updatedLabel, presentation.updatedText)
                if let marker = presentation.lifecycleMarkerText {
                    LifecycleMarker(text: marker)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isRovingRow ? Theme.selected.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle(cornerRadius: 0, focusInset: 2))
        .accessibilityIdentifier("work.table.task.\(task.taskId)")
        .accessibilityLabel(presentation.accessibilityLabel)
        .workRowAccessibilityFields(presentation.accessibilityFields)
    }

    private func labelledValue(_ label: String, _ value: String, absent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CapsLabel(text: label)
            Text(value).workFont(.caption).foregroundStyle(absent ? Theme.muted : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Receipt master (wide record mode)

/// The table's compact sibling, not a separate navigation universe. It shares
/// the exact query/group/sort model and keeps enough evidence context visible
/// to compare Tasks while a receipt is open.
private struct WorkMasterList: View {
    @Environment(DashboardStore.self) var dashboard
    @Environment(AppSelection.self) var selection
    @ObservedObject var browse: WorkBrowseState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTaskId: String?
    @FocusState private var searchFocused: Bool
    @State private var isRetryingAttention = false

    private var visibleTasks: [ReceiptSummary] {
        browse.visibleTasks(in: dashboard.receiptTasks, attention: dashboard.attention)
    }

    private var sourceTasks: [ReceiptSummary] {
        browse.group == .attention ? dashboard.attention?.items ?? [] : dashboard.receiptTasks
    }

    private var collectionError: String? {
        browse.group == .attention ? dashboard.attentionError : dashboard.receiptListError
    }

    private var isLoadingCollection: Bool {
        if browse.group == .attention {
            return isRetryingAttention || (dashboard.attention == nil && dashboard.attentionError == nil)
        }
        return dashboard.isLoadingReceipts
    }

    private var collectionCount: String {
        if browse.group == .attention {
            guard let attention = dashboard.attention else {
                return collectionError == nil ? "Loading \(dashboard.attentionQueue?.noun ?? "the review queue")…" : "Review status unavailable"
            }
            let count = PayloadAbsence.text(attention.queue?.countText) ?? "\(attention.total) in queue"
            if attention.truncated {
                return "\(visibleTasks.count) of \(attention.items.count) loaded · \(count)"
            }
            return "\(visibleTasks.count) of \(count)"
        }
        return workBrowseCountText(
            visible: visibleTasks.count,
            loaded: dashboard.receiptTasks.count,
            total: dashboard.totalReceiptTasks,
            truncated: dashboard.receiptTasksTruncated,
            pageIsLoaded: workReceiptPageIsLoaded(
                loadedCount: dashboard.receiptTasks.count,
                isLoading: isLoadingCollection,
                error: collectionError
            )
        )
    }

    private var renderedTasks: [ReceiptSummary] {
        guard SnapshotMode.enabled else { return visibleTasks }
        return Array(visibleTasks.prefix(7))
    }

    private var selectionIsOutsideBrowse: Bool {
        workSelectionIsOutsideBrowse(
            taskId: selection.taskId,
            allTasks: sourceTasks,
            visibleTasks: visibleTasks
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Tasks").workFont(.titleCard).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(collectionCount)
                    .workFont(.dataSmall).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.l)

            masterControls.padding(Space.l)
            if selectionIsOutsideBrowse {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("Selected receipt is outside these filters")
                        .workFont(.dataSmall).foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    Button("Show") {
                        browse.query = ""
                        if browse.group != .attention { browse.group = nil }
                    }
                    .buttonStyle(QuietButtonStyle(tint: Theme.accent))
                    .accessibilityIdentifier("work.master.show-selection")
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)
                .accessibilityElement(children: .contain)
            }
            if let error = collectionError, !sourceTasks.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isLoadingCollection, !SnapshotMode.enabled {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .workFont(.icon).foregroundStyle(Theme.amber)
                            .accessibilityHidden(true)
                    }
                    Text(isLoadingCollection ? "Retrying · showing saved list" : "Showing saved list · refresh failed")
                        .workFont(.dataSmall).foregroundStyle(Theme.muted)
                        .help(error)
                    Spacer(minLength: 0)
                    if !SnapshotMode.enabled, !isLoadingCollection {
                        Button("Retry", action: retryCollection)
                            .buttonStyle(QuietButtonStyle(tint: Theme.accent))
                            .accessibilityIdentifier("work.master.retry")
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)
                .accessibilityElement(children: .contain)
            }
            Rectangle().fill(Theme.rule).frame(height: 1)

            ScrollViewReader { scrollProxy in
                ScrollBox {
                    ScrollContentStack(spacing: 0) {
                    if isLoadingCollection, sourceTasks.isEmpty {
                        masterEmpty(
                            title: browse.group == .attention ? "Loading \(dashboard.attentionQueue?.noun ?? "the review queue")" : "Loading receipts",
                            message: nil
                        )
                    } else if let error = collectionError, sourceTasks.isEmpty {
                        EmptyStateView(
                            title: browse.group == .attention
                                ? "Review queue unavailable"
                                : WorkTablePage.taskListUnavailableTitle,
                            cause: browse.group == .attention
                                ? "The recorder didn't return the review queue."
                                : WorkTablePage.taskListUnavailableCause,
                            detailDisclosure: error,
                            action: .init(
                                label: WorkTablePage.retryLabel,
                                identifier: "work.master.retry",
                                perform: retryCollection
                            ),
                            identifier: "work.master.unavailable"
                        )
                        .padding(.horizontal, Space.l)
                        .padding(.vertical, Space.xl)
                    } else if visibleTasks.isEmpty {
                        if browse.group == .attention, let attention = dashboard.attention {
                            let copy = WorkAttentionEmptyCopy(payload: attention, query: browse.query)
                            EmptyStateView(
                                title: copy.title,
                                cause: copy.detail,
                                action: attention.total > 0 && attention.items.isEmpty
                                    ? .init(
                                        label: WorkTablePage.retryLabel,
                                        identifier: "work.master.retry",
                                        perform: retryCollection
                                    )
                                    : nil,
                                identifier: "work.master.empty"
                            )
                            .padding(.horizontal, Space.l)
                            .padding(.vertical, Space.xl)
                        } else {
                            EmptyStateView(
                                title: dashboard.receiptTasks.isEmpty
                                    ? WorkTablePage.noTasksRecordedTitle : "No matching tasks",
                                cause: dashboard.receiptTasks.isEmpty
                                    ? "Recorded work will appear here."
                                    : "Clear the filter or choose another status.",
                                identifier: "work.master.empty"
                            )
                            .padding(.horizontal, Space.l)
                            .padding(.vertical, Space.xl)
                        }
                    } else {
                        ForEach(renderedTasks) { task in
                            WorkMasterRow(
                                presentation: .init(
                                    task: task,
                                    detail: task.taskId == selection.taskId ? dashboard.receipt : nil,
                                    listLabels: dashboard.receiptFieldLabels
                                ),
                                selected: task.taskId == selection.taskId,
                                focus: $focusedTaskId
                            ) {
                                selection.sessionId = nil
                                selection.taskId = task.taskId
                            }
                            .id(task.taskId)
                        }
                    }
                    if SnapshotMode.enabled, visibleTasks.count > renderedTasks.count {
                        Text("… \(visibleTasks.count - renderedTasks.count) more")
                            .workFont(.dataSmall).foregroundStyle(Theme.muted)
                            .padding(Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                }
                .onMoveCommand { direction in moveSelection(direction, scrollProxy: scrollProxy) }
                .onAppear { focusSelectedRowIfVisible() }
                .onChange(of: selection.taskId) { focusSelectedRowIfVisible() }
            }
            if browse.group == .attention, dashboard.attention?.truncated == true {
                Button(dashboard.isLoadingMoreAttention ? "Loading…" : "Load more") {
                    Task { await dashboard.fetchMoreAttention() }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(dashboard.isLoadingMoreAttention || isRetryingAttention)
                .padding(Space.l)
                .accessibilityIdentifier("work.attention.load-more")
            }
        }
        .background(Theme.chrome)
        .focusedSceneValue(\.focusSearch, FocusSearchAction { searchFocused = true })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.master")
    }

    private var masterControls: some View {
        VStack(spacing: Space.s) {
            AppTextField(
                placeholder: "Search tasks",
                text: $browse.query,
                systemImage: "magnifyingglass",
                focus: $searchFocused,
                accessibilityIdentifier: "work.master.search"
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // The same caption + app-owned picker form as the table controls.
            HStack(spacing: 0) {
                WrappingRowLayout(horizontalSpacing: Space.s, verticalSpacing: Space.xs) {
                    Text("Status").workFont(.caption).foregroundStyle(Theme.muted)
                    AppMenuPicker(
                        title: "Status",
                        selection: $browse.group,
                        options: statusOptions,
                        accessibilityIdentifier: "work.master.status"
                    )
                    Text("Sort").workFont(.caption).foregroundStyle(Theme.muted)
                    AppMenuPicker(
                        title: "Sort",
                        selection: $browse.sort,
                        options: WorkSort.allCases.map { ($0, $0.rawValue) },
                        accessibilityIdentifier: "work.master.sort"
                    )
                    DecisionLegendButton(
                        legend: dashboard.decisionLegend,
                        tierLegend: dashboard.receipt?.axes.evidenceStrength.tierLegend,
                        definition: dashboard.receipt?.axes.evidenceStrength.definition
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusOptions: [(WorkGroup?, String)] {
        var options: [(WorkGroup?, String)] = [(nil, "All statuses")]
        for group in WorkGroup.allCases { options.append((group, group.label(in: dashboard.decisionLegend))) }
        return options
    }

    private func retryCollection() {
        if browse.group == .attention {
            guard !isRetryingAttention else { return }
            isRetryingAttention = true
            Task {
                defer { isRetryingAttention = false }
                await dashboard.fetchAttention()
            }
        } else {
            Task { await dashboard.fetchReceipts() }
        }
    }

    private func masterEmpty(title: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).workFont(.rowLabel).foregroundStyle(Theme.ink)
            if let message {
                Text(message).workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveSelection(
        _ direction: MoveCommandDirection,
        scrollProxy: ScrollViewProxy
    ) {
        guard direction == .up || direction == .down, !visibleTasks.isEmpty else { return }
        let current = visibleTasks.firstIndex { $0.taskId == selection.taskId }
        let nextIndex: Int
        switch direction {
        case .up: nextIndex = max(0, (current ?? 1) - 1)
        case .down: nextIndex = min(visibleTasks.count - 1, (current ?? -1) + 1)
        default: return
        }
        let task = visibleTasks[nextIndex]
        focusedTaskId = task.taskId
        selection.sessionId = nil
        selection.taskId = task.taskId
        withAnimation(reduceMotion ? nil : Motion.hover) {
            scrollProxy.scrollTo(task.taskId, anchor: .center)
        }
    }

    private func focusSelectedRowIfVisible() {
        guard !SnapshotMode.enabled,
              let taskId = selection.taskId,
              visibleTasks.contains(where: { $0.taskId == taskId }) else { return }
        DispatchQueue.main.async { focusedTaskId = taskId }
    }
}

private struct WorkMasterRow: View {
    let presentation: WorkReceiptRowPresentation
    let selected: Bool
    let focus: FocusState<String?>.Binding
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(presentation.title)
                        .workFont(size: 13, weight: selected ? .semibold : .regular, relativeTo: .body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .help(presentation.title)
                    Spacer(minLength: 4)
                    DecisionBadge(
                        key: presentation.decisionKey,
                        label: presentation.decisionLabel,
                        compact: true,
                        help: presentation.decisionHelp
                    )
                }

                if let reason = presentation.attentionReason, !reason.isEmpty {
                    Text(verbatim: reason)
                        .workFont(.caption).foregroundStyle(presentation.attentionReasonTint)
                        .lineLimit(2)
                }

                HStack(spacing: 5) {
                    Text(presentation.clientText)
                    Spacer(minLength: 4)
                    Text(presentation.updatedText)
                }
                .workFont(.dataSmall).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selected : (focus.wrappedValue == presentation.taskId ? Theme.selected.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle(cornerRadius: 0, focusInset: 2))
        .focused(focus, equals: presentation.taskId)
        .focusable(selected)
        // The selection bar rides as an overlay so it can never stretch the row.
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 4) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, Space.l)
        }
        // NOT `.accessibilityElement(children: .ignore)`: that replaces the
        // Button's own element, and the split list's rows lost their button
        // role and their press action with it — VoiceOver could not open a
        // task from the default layout (K118). The Button already speaks as
        // one element; the label below is what it says.
        .accessibilityLabel(presentation.accessibilityLabel)
        .workRowAccessibilityFields(presentation.accessibilityFields)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("work.master.task.\(presentation.taskId)")
    }
}

// MARK: - Record page

/// A task prioritizes current status and recorded activity. Supporting ledgers
/// open only after the user asks for that category of detail.
/// What Escape should close first inside a record. The timeline publishes a
/// dismissal while it holds a transient layer open (the inspector, a dense
/// group's chooser); the record page runs that instead of leaving the record,
/// so Escape closes ONE layer at a time wherever the focus happens to sit —
/// it used to depend on which control had focus, and from the overview strip
/// a single Escape threw away the open inspector and the record with it (K116).
@MainActor
@Observable
final class WorkRecordLayers {
    /// Set by whichever layer is open. Observation must NOT track it: the
    /// timeline writes it from an `onChange`, and a tracked write there would
    /// invalidate the record page on every selection.
    @ObservationIgnored var dismissInnermost: (() -> Void)?
    /// A request from elsewhere on the record page — the Checks table — to
    /// select one recorded event in the activity surface. The counter makes a
    /// repeat request for the SAME event observable.
    private(set) var selectEventID: String?
    private(set) var selectRequest = 0

    func selectEvent(_ eventID: String) {
        selectEventID = eventID
        selectRequest += 1
    }
}

struct WorkRecordPage: View {
    let receipt: Receipt
    let summary: ReceiptSummary?
    let refreshError: String?
    let isRefreshing: Bool
    let autoFocusEntry: Bool
    var timelineFocused = false
    var onToggleTimelineFocus: (() -> Void)? = nil
    @Environment(AppSelection.self) var selection
    @Environment(DashboardStore.self) var dashboard
    @Environment(\.workCompactViewport) private var compactViewport
    @FocusState private var backFocused: Bool
    @AccessibilityFocusState private var backAccessibilityFocused: Bool
    @AccessibilityFocusState private var headingAccessibilityFocused: Bool
    @State private var layers = WorkRecordLayers()

    private var denseHeader: Bool { timelineFocused || compactViewport }
    /// Section names come from the reducer's `field_labels` (C39).
    private var labels: ReceiptFieldLabels { receipt.fieldLabels ?? ReceiptFieldLabels() }
    /// The anchor a freshly opened record scrolls to: the top of the page.
    static let topAnchor = "work.record.top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollBox {
                VStack(alignment: .leading, spacing: 0) {
                    breadcrumb.id(Self.topAnchor)
                    // A breakpoint changes arrangement and padding, never the
                    // set of facts: the dense header is the same verdict stack.
                    verdictHero(dense: denseHeader)
                        .padding(.top, denseHeader ? Space.s : Space.m)
                    // The reducer's one attention block, for every kind (failed
                    // check, blocker, failed step). A dispositioned item keeps
                    // its callout in a neutral tone so it stays reopenable.
                    if let attention = receipt.attention {
                        AttentionCallout(
                            attention: attention,
                            taskId: receipt.taskId,
                            blocker: receipt.axes.decisionStatus.blocker
                        )
                        .padding(.top, Space.s)
                    } else if let proof = standingProof {
                        // The same reserved slot, filled the other way. It used
                        // to render ONLY on trouble, so a Task whose checks all
                        // passed showed less evidence than one that failed (C3).
                        EvidenceCallout(proof: proof, title: labels.checksLabel)
                            .padding(.top, Space.s)
                    }
                    // The receipt's totals sit with the header, above the
                    // evidence: verdict, then line items, then history.
                    RecordSummaryStrip(receipt: receipt, summary: summary)
                        .padding(Space.l)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.radius))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.cardLine))
                        .padding(.top, denseHeader ? Space.s : Space.l)
                    // The recorded runs themselves, between the totals and the
                    // activity surface: the evidence the tally above counts,
                    // earlier runs greyed rather than elided.
                    ReceiptSection(
                        title: labels.checksLabel, identifier: "checks",
                        help: PayloadAbsence.text(receipt.dimensions.evidence.checkTallyText)
                    ) {
                        RecordChecksSection(receipt: receipt, layers: layers)
                    }
                    .padding(.top, denseHeader ? Space.m : Space.l)
                    WorkTimelineView(receipt: receipt,
                        layers: layers,
                        // Reveal the inspector without pushing the canvas off-screen.
                        onRevealInspector: { proxy.scrollTo("work.timeline.inspector", anchor: .bottom) },
                        onRevealRecords: { proxy.scrollTo("work.timeline.records", anchor: .top) },
                        onRevealHeading: { proxy.scrollTo("work.timeline.heading", anchor: .top) })
                        .padding(.top, Space.m)
                    // Below the timeline, the receipt's second half is a
                    // visible document — not a fold. Sections are always shown
                    // (verdict → totals → history → the record); only a
                    // genuinely long list collapses, one level deep, with the
                    // count in its trigger.
                    VStack(alignment: .leading, spacing: Space.xl) {
                        ReceiptSection(
                            title: "Usage", identifier: "usage",
                            help: "Counts describe captured tool calls, not progress or success. Related paths are recorded associations, not modified files. Current receipts have no ordered action ledger, so captured call counts cannot be linked to results or timing."
                        ) {
                            RecordDimensionsCard(receipt: receipt, included: [.actions, .cost],
                                                 showsProvenance: false, compactDigest: true)
                        }
                        ReceiptSection(title: "Sessions", identifier: "sessions") {
                            sessionsIndex
                        }
                        ReceiptSection(title: "Recording", identifier: "recording",
                                       help: recordingHelp) {
                            recordingDetails
                        }
                    }
                    .padding(.top, Space.xl)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("work.all-captured-details")
                }
                .padding(denseHeader ? Space.m : Space.gutter)
                .modifier(WorkRecordPageFrame(unbounded: timelineFocused))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(receipt.taskId)  // reset the drill-down's expansion state per Task
            // One Escape route for the whole record, layer by layer (K116).
            .background { if !SnapshotMode.enabled { escapeKeyHandler } }
            .onKeyPress(.escape) { escapePressed(); return .handled }
            .onAppear {
                guard !SnapshotMode.enabled else { return }
                if selection.workEntry == .navigate {
                    // A record OPENS at its verdict. Landing part-way down the
                    // activity canvas — which is where a restored inspector
                    // used to pull the page — hid the decision, the attention
                    // callout and the recorded next step the reviewer came
                    // for (K104). A deliberate return keeps its position.
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                    DispatchQueue.main.async { headingAccessibilityFocused = true }
                }
                guard autoFocusEntry else { return }
                DispatchQueue.main.async {
                    backFocused = true
                    backAccessibilityFocused = true
                }
            }
        }
    }

    /// The Recording section's definition, from the payload: what the coverage
    /// counts mean, then how the two axes relate.
    private var recordingHelp: String? {
        let parts = [
            PayloadAbsence.text(receipt.axes.evidenceStrength.definition),
            PayloadAbsence.text(receipt.axes.orthogonalityNote),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// An unmistakable back control (the old caps "WORK" read as a static path
    /// label, not a button) + the path itself. Esc triggers the same return.
    private var breadcrumb: some View {
        HStack(spacing: Space.m) {
            backButton
            Spacer(minLength: 0)
            if let onToggleTimelineFocus, !compactViewport || timelineFocused {
                Button(action: onToggleTimelineFocus) {
                    Label(timelineFocused ? "Show task list" : "Focus timeline", systemImage: timelineFocused ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                        .workFont(.captionSemibold)
                }.buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                .accessibilityIdentifier("work.focus-timeline")
            }
        }
    }

    @ViewBuilder
    private var backButton: some View {
        // ImageRenderer blanks controls carrying AccessibilityFocusState.
        // The live path retains it; snapshots render the same visible button.
        if SnapshotMode.enabled {
            backButtonBase
        } else {
            backButtonBase.accessibilityFocused($backAccessibilityFocused)
        }
    }

    /// Leave the record for the task collection, restoring the row's focus.
    private func leaveRecord() {
        selection.workBrowse.prepareReturnFocus(
            from: receipt.taskId,
            in: dashboard.receiptTasks,
            attention: dashboard.attention
        )
        selection.taskId = nil
        selection.sessionId = nil
    }

    /// Escape, from anywhere in the record: close the innermost open layer if
    /// there is one, else leave the record (K116).
    private func escapePressed() {
        if let dismiss = layers.dismissInnermost {
            dismiss()
            return
        }
        leaveRecord()
    }

    /// The window-level Escape key equivalent. It lives on its own zero-sized
    /// button rather than on the back button: a key equivalent is handled
    /// before the focused view's own key press, so the back button used to
    /// claim Escape even while an inner layer was open — but keeping the
    /// equivalent is what makes Escape work when focus has fallen back to the
    /// window, so it is routed through the layer check instead of removed.
    private var escapeKeyHandler: some View {
        Button("Back to all tasks", action: escapePressed)
            .keyboardShortcut(.cancelAction)
            .buttonStyle(QuietButtonStyle())
            .frame(width: 0, height: 0)
            .opacity(0)
            // It carries a key equivalent, nothing else: never a Tab stop
            // (an invisible one is exactly what K115 found), never hit-
            // testable, and not in the accessibility tree — the visible
            // "All tasks" button is the control that does this job.
            .focusable(false)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var backButtonBase: some View {
        Button(action: leaveRecord) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .workFont(.icon)
                    .accessibilityHidden(true)
                Text("All tasks").workFont(.captionSemibold)
            }
            .foregroundStyle(Theme.accent)
            .minimumHitTarget(alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(horizontalPadding: 6, verticalPadding: 3))
        .focused($backFocused)
        .help("Back to all tasks (Esc)")
        .accessibilityLabel("All tasks")
        .accessibilityIdentifier("work.breadcrumb.back")
    }

    // A human-review-first header: the decision badge with the proof clause
    // beside it (never the decision word twice), the evidence coverage made
    // visual (a counted legend only when 2+ tiers need telling apart), the
    // unproven part called out, and what the ratio does not cover beneath it.
    // The ratio appears once, in the clause; its date bound rides the meta
    // line. The two axes stay two colours — the decision badge on the
    // decision palette, the coverage meter on the evidence ramp. `dense`
    // tightens type and padding; every fact stays.
    @ViewBuilder
    private func verdictHero(dense: Bool) -> some View {
        let decision = receipt.axes.decisionStatus
        let evidence = receipt.axes.evidenceStrength
        VStack(alignment: .leading, spacing: dense ? Space.s : Space.m) {
            let ramp = VerdictHeroTypeRamp(dense: dense)
            // Provenance before the claim (K55): a verdict a reviewer reads as
            // current must not appear above the notice that it is a saved
            // copy. The notice carries WHEN the copy was taken, because the
            // receipt's own "updated 2m ago" froze at that moment.
            if let refreshError {
                staleCopyNotice(refreshError)
            }
            // ImageRenderer blanks views carrying AccessibilityFocusState, so
            // only the live path takes the entry focus (as `backButton` does).
            heroTitle(ramp: ramp)
            // ONE state row. The decision badge is the primary state; the
            // handoff marker is sent only when it ADDS to that word, so the two
            // read as one state, not as competing chips. The proof clause used
            // to sit here at the largest size on the page — it is a figure, and
            // it now rides the tile strip with the other figures.
            WrappingRowLayout(horizontalSpacing: dense ? Space.s : Space.m, verticalSpacing: Space.xs) {
                DecisionBadge(
                    key: decision.key,
                    label: decision.label ?? decision.key,
                    compact: dense,
                    help: decision.statement
                )
                if let marker = PayloadAbsence.text(receipt.lifecycleMarkerText) {
                    LifecycleMarker(text: marker)
                }
                DecisionLegendButton(
                    legend: dashboard.decisionLegend,
                    tierLegend: evidence.tierLegend,
                    definition: evidence.definition,
                    scopeDefinition: (evidence.notCheckable ?? 0) > 0 ? evidence.scopeDefinition : nil
                )
            }
            // What the state MEANT for the work, directly under it: the agent's
            // own outcome words, at the ramp's consequence step and still
            // labelled as its report — a claim, never a verified statement.
            if let summary = PayloadAbsence.text(receipt.dimensions.outcome.summary) {
                AgentOutcomeSummary(
                    summary: summary,
                    label: PayloadAbsence.text(receipt.dimensions.outcome.summaryLabel) ?? PayloadAbsence.source,
                    // The byline says WHO reported this and, when it helps,
                    // which section it came from. On a one-section Task the
                    // section IS the Task, so the byline printed the page
                    // heading back at the reader a line below itself (F1). A
                    // section title that only repeats the heading carries
                    // nothing, so the byline drops to the source alone.
                    sectionTitle: sectionTitleBeyondTheHeading,
                    role: ramp.consequence,
                    tracking: ramp.consequenceTracking
                )
            }
            // The agent's recorded continuation point, on EVERY record — not
            // only on one that still needs you (F6). It used to render solely
            // inside the attention callout, so marking a finding reviewed took
            // the one line that says what happens next off the page with it.
            NextStepRow(text: recordedNextStep)
                .padding(.top, Space.xs)
            coverageMeter(evidence: evidence)
            if let verdict = receipt.verdict, let gapLine = verdict.gapLine {
                verdictGapCallout(gapLine, unproven: verdict.gapIsUnproven)
            }
            if !metaLine.isEmpty {
                Text(metaLine).workFont(.dataSmall).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let boundaryGap = boundaryGapText {
                Text(boundaryGap).workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
            }
        }
        .padding(dense ? Space.m : Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.cardLine))
    }

    /// The receipt's standing proof — the passing run a `Verified` hero rests
    /// on. Nil when no check passed, which is itself why a hero has no proof
    /// qualifier to show.
    private var standingProof: ReceiptStandingProof? { ReceiptStandingProof(receipt: receipt) }

    /// The outcome byline's section title, kept ONLY when it says something the
    /// page heading above it does not. Two payload strings compared — no
    /// wording is composed here.
    private var sectionTitleBeyondTheHeading: String? {
        guard let section = PayloadAbsence.text(receipt.dimensions.outcome.summarySectionTitle) else { return nil }
        let heading = PayloadAbsence.text(receipt.title) ?? receipt.taskId
        return restatesPayloadText(section, heading) ? nil : section
    }

    /// The recorded next step this record shows. The Task's own outcome field
    /// is the record's answer; an older payload that carried the step only on
    /// the attention item still has one to show. A missing one is NAMED by
    /// `NextStepRow`, never left as an empty slot.
    private var recordedNextStep: String? {
        PayloadAbsence.text(receipt.dimensions.outcome.nextStep)
            ?? PayloadAbsence.text(receipt.attention?.nextStep)
    }


    /// The coverage meter and everything a reader needs to read it (C2).
    ///
    /// The bar had no caption, no legend, no scale and no denominator: it drew
    /// `checked / checkable`, so `1/1 self-checked` filled the whole track on a
    /// five-step Task with two steps still open. It is now drawn over EVERY
    /// recorded step, with the open and out-of-scope spans visually distinct,
    /// so a partial record physically cannot fill it. Beneath it: the reducer's
    /// ledger line naming those spans, its definition of what the ratio
    /// measures, and — when the proving run was recorded on a dirty tree — the
    /// revision label that qualifies the proof (C5).
    @ViewBuilder
    private func coverageMeter(evidence: ReceiptEvidence) -> some View {
        let bar = CoverageBar(evidence: evidence)
        let ledger = PayloadAbsence.text(receipt.verdict?.ledgerText)
            ?? PayloadAbsence.text(evidence.coverageLedger)
        let dirtyProof = standingProof?.dirtyRevisionLabel
        VStack(alignment: .leading, spacing: Space.s) {
            // A Task with no recorded step has no meter to caption: the
            // Coverage tile carries its named absence and the ledger, if the
            // reducer sent one, still names what is outside the ratio.
            if bar.denominator > 0 {
                CapsLabel(text: labels.coverageLabel)
                bar.frame(maxWidth: 460, alignment: .leading)
            }
            if let ledger {
                // The bar's legend: the payload's own sentence for the spans
                // that own no proof claim. Composing "2 steps still open" per
                // segment in Swift would be a second vocabulary, so the
                // reducer's one sentence names them together.
                Text(ledger).workFont(FieldFont.gapLine).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
                    .modifier(OptionalHelp(
                        text: (evidence.notCheckable ?? 0) > 0 ? PayloadAbsence.text(evidence.scopeDefinition) : nil
                    ))
            }
            if bar.denominator > 0, let definition = PayloadAbsence.text(evidence.definition) {
                // What the meter measures, in the reducer's words. A meter with
                // no caption at all was the state this replaces.
                Text(definition).workFont(FieldFont.qualifier).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
            }
            if let dirtyProof {
                // The proving run's own revision line, verbatim: a hero that
                // says Verified over a tree with uncommitted changes owes the
                // reader that qualifier.
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    CaveatMarker()
                    Text(verbatim: dirtyProof)
                        .workFont(FieldFont.qualifier).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(joinedRecordedSentences([
            labels.coverageLabel,
            PayloadAbsence.text(evidence.coverageRow),
            ledger,
            dirtyProof,
        ]))
        .accessibilityIdentifier("work.record.coverage")
    }

    /// The reducer's gap line as it arrives (`Not yet proven — …` only for an
    /// evidence gap). The glyph is chosen from the TYPED gap (K05): only a
    /// reducer-labelled unproven part (`gap_label` present) wears the hollow
    /// unchecked pip; any other gap (open steps, scope counts) is caveat
    /// prose with the caveat marker, never a tier shape. Prose stays muted.
    @ViewBuilder
    private func verdictGapCallout(_ gapLine: String, unproven: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            if unproven {
                EvidencePip(grade: "unchecked", radius: Type.icon / 2)
            } else {
                CaveatMarker()
            }
            Text(gapLine)
                .workFont(FieldFont.gapLine).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tintNeutral, in: RoundedRectangle(cornerRadius: Metrics.radius))
    }

    @ViewBuilder
    private func heroTitle(ramp: VerdictHeroTypeRamp) -> some View {
        let title = Text(receipt.title ?? receipt.taskId)
            .workFont(ramp.title)
            .tracking(ramp.titleTracking)
            .foregroundStyle(Theme.ink).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        if SnapshotMode.enabled {
            title
        } else {
            title.accessibilityFocused($headingAccessibilityFocused)
        }
    }

    /// The saved-copy line inside the verdict header. It names the copy's
    /// absolute age with `Fmt.savedAt`, the same spelling the offline banner
    /// uses, so the one fact reads the same on both surfaces.
    private var staleCopyText: String {
        guard let copiedAt = dashboard.currentReceiptCopiedAt else {
            return "Saved copy · refresh failed · copy time not recorded"
        }
        return "Saved copy from \(Fmt.savedAt(copiedAt)) · refresh failed"
    }

    private func staleCopyNotice(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle")
                .workFont(.icon)
                .foregroundStyle(Theme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(staleCopyText)
                    .workFont(.rowLabel).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error).workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
            }
            Spacer(minLength: Space.m)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Retrying receipt refresh")
            } else {
                Button("Retry") {
                    Task { await dashboard.fetchReceipt(taskId: receipt.taskId) }
                }
                .buttonStyle(QuietButtonStyle(tint: Theme.accent))
                .workFont(.captionSemibold)
                .accessibilityIdentifier("work.receipt.stale.retry")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Amber: the state is unverified, not a failure — and it sits INSIDE
        // the header card, so the wash keeps its own rule (C42).
        .background(Theme.tintAmberOnCanvas, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius)
                .strokeBorder(Theme.rule, lineWidth: Metrics.borderW)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(staleCopyText). \(error)")
        .accessibilityIdentifier("work.receipt.stale")
    }

    private var metaLine: String {
        // The project is meta, so it lives here beside the client — not
        // appended into the Task objective sentence. The boundary's own name
        // wins, so the meta line and the boundary gap below agree. The order
        // itself comes from the one helper every surface calls (K21).
        let project = PayloadAbsence.text(receipt.dimensions.task.boundary?.project)
            ?? PayloadAbsence.text(summary?.project)
        return workMetaLine(
            client: summary?.primaryRoot?.client,
            project: project,
            trailing: [
                agoText(summary?.lastActivityAt).map { "updated \($0)" },
                // The date bound on the counts (`Counts since Sep 14`) — meta,
                // not a second statement of the ratio.
                PayloadAbsence.text(receipt.verdict?.healthWindow?.text),
            ]
        )
    }

    /// The reducer's boundary gap sentence (`Sessions in this Task report
    /// different projects.`), nil — and hidden — when the project is declared.
    private var boundaryGapText: String? {
        PayloadAbsence.text(receipt.dimensions.task.boundary?.gapText)
    }

    private var topicDivider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    /// A session index, not a second copy of the timeline: one quiet row per
    /// session. Steps stay on the activity canvas.
    @ViewBuilder
    private var sessionsIndex: some View {
        if let groups = receipt.sessions, !groups.isEmpty {
            let labelled = groups.count > 1
            VStack(alignment: .leading, spacing: 0) {
                // The primary group is always visible; any further groups
                // (continuations, extra roots) collapse under one counted
                // trigger so a long roster never buries the primary session.
                sessionGroup(groups[0], labelled: labelled)
                if groups.count > 1 {
                    let rest = Array(groups.dropFirst())
                    let restCount = rest.reduce(0) { $0 + $1.members.count }
                    OverflowDisclosure(
                        label: "\(restCount) more session\(restCount == 1 ? "" : "s")",
                        identifier: "work.overflow.sessions"
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rest) { group in
                                sessionGroup(group, labelled: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            Text("Session details aren't available for this receipt.")
                .workFont(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
        }
    }

    /// One session group: an optional role header and its member rows.
    @ViewBuilder
    private func sessionGroup(_ group: ReceiptSessionGroup, labelled: Bool) -> some View {
        let members = group.members
        VStack(alignment: .leading, spacing: 0) {
            if labelled {
                HStack(spacing: Space.s) {
                    CapsLabel(text: group.role == "continuation" ? "Continuation" : "Primary")
                    if let count = group.supportingCount, count > 0 {
                        Text("\(count) subagent\(count == 1 ? "" : "s")")
                            .workFont(.dataSmall).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, Space.s).padding(.bottom, 2)
            }
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                SessionIndexRow(
                    member: member,
                    preloadedStepCount: dashboard.preloadedSessions["\(member.client)::\(member.clientSessionId)"]?.steps.count,
                    taskTitle: receipt.title
                )
                if index < members.count - 1 { topicDivider }
            }
        }
    }

    /// The provenance sources as the reducer labels them; an older payload
    /// without labelled entries falls back to the keys it listed.
    private var sourceEntries: [ReceiptSourceEntry] {
        let provenance = receipt.dimensions.provenance
        if let sources = provenance.sources, !sources.isEmpty { return sources }
        return (provenance.sourcesPresent ?? []).map { key in
            ReceiptSourceEntry(
                key: key,
                label: provenance.sourceLabel(for: key),
                legend: provenance.legend?[key],
                tierKey: nil,
                tierLabel: nil
            )
        }
    }

    /// Identity and provenance in one place: task and agent facts, sources
    /// and gaps. Coverage lives in the verdict hero (its definition in this
    /// section's help); each fact appears once on the page.
    private var recordingDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordDimensionsCard(receipt: receipt, included: [.task, .agents],
                                 showsProvenance: false, showsGaps: false)
            receiptFactRow("Sources") {
                let entries = sourceEntries
                if entries.isEmpty {
                    Text(PayloadAbsence.text(receipt.dimensions.provenance.sourcesAbsentText) ?? PayloadAbsence.source)
                        .workFont(.body).foregroundStyle(Theme.muted)
                } else {
                    let legendLines = entries.compactMap { entry -> String? in
                        guard let legend = PayloadAbsence.text(entry.legend) else { return nil }
                        return "\(PayloadAbsence.text(entry.label) ?? entry.key): \(legend)"
                    }
                    HStack(alignment: .top, spacing: Space.s) {
                        WrappingRowLayout(horizontalSpacing: 6, verticalSpacing: Space.xs) {
                            ForEach(entries) { entry in
                                ProvenanceChip(text: PayloadAbsence.text(entry.label) ?? entry.key)
                            }
                        }
                        // Each source's legend sentence is the daemon's own,
                        // keyboard-openable rather than hover-only.
                        if !legendLines.isEmpty {
                            ContextHelp(
                                title: "About these sources",
                                message: legendLines.joined(separator: "\n"),
                                identifier: "work.recording.sources.help"
                            )
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            let gapsDim = receipt.dimensions.gaps
            receiptFactRow("Gaps") {
                // The boundary gap already shows under the verdict's meta line;
                // it is not repeated here.
                let items = (gapsDim.items ?? []).filter { item in
                    boundaryGapText.map { item.reason != $0 } ?? true
                }
                let removed = (gapsDim.items ?? []).count - items.count
                let count = max((gapsDim.count ?? (gapsDim.items ?? []).count) - removed, 0)
                if count == 0 {
                    Text("no recorded gaps").workFont(.body).foregroundStyle(Theme.muted)
                } else if items.isEmpty {
                    Text("\(count) recorded gap\(count == 1 ? "" : "s") · details not included")
                        .workFont(.caption).foregroundStyle(Theme.muted)
                } else {
                    // Detailed gaps beyond the third fold into one counted
                    // trigger; any gaps counted without detail are named too, so
                    // the remaining total is honest whichever form the extras take.
                    let undetailed = max(count - items.count, 0)
                    VStack(alignment: .leading, spacing: 4) {
                        // Index-stable identity: two gaps sharing a dimension and
                        // reason must both render, never collapse into one row.
                        ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in gapRow(item) }
                        if items.count > 3 {
                            let remaining = (items.count - 3) + undetailed
                            OverflowDisclosure(
                                label: "\(remaining) more gap\(remaining == 1 ? "" : "s")",
                                identifier: "work.overflow.gaps"
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(items.dropFirst(3).enumerated()), id: \.offset) { _, item in gapRow(item) }
                                    if undetailed > 0 {
                                        Text("\(undetailed) more recorded gap\(undetailed == 1 ? "" : "s") · details not included")
                                            .workFont(.caption).foregroundStyle(Theme.muted)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .padding(.top, 2)
                        } else if undetailed > 0 {
                            Text("\(undetailed) more recorded gap\(undetailed == 1 ? "" : "s") · details not included")
                                .workFont(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            receiptFactRow("Task ID") {
                CopyableValue(text: receipt.taskId, announce: "task ID")
            }
        }
    }

    /// One recorded gap: the caveat marker (a gap is not an evidence tier, so
    /// it never wears a pip shape), the dimension naming where the blind spot
    /// is, and the reason stating it.
    private func gapRow(_ item: ReceiptGapItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            CaveatMarker()
            Text(item.label).workFont(.captionSemibold).foregroundStyle(Theme.muted)
                .frame(width: 76, alignment: .leading)
            Text(item.reason).workFont(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
        }
        // The dimension names where the blind spot is and the sentence states
        // it: one fact, one element (K124).
        .accessibilityElement(children: .combine)
    }

    /// One labelled fact of the record. Every row here holds a control (copy,
    /// context help) or a disclosure, so the row is a NAMED container rather
    /// than one combined element: the field name is announced on entry and the
    /// control inside keeps its own role and action (K124/K118). Rows whose
    /// value is pure prose combine label and value instead — see
    /// `RecordDimensionsCard.dimensionRow`.
    private func receiptFactRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: Space.l) {
            CapsLabel(text: label)
                .frame(width: 104, alignment: .leading)
                .padding(.top, 3)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { topicDivider }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The record page's width rule: the one page cap, except while the timeline
/// is focused and deliberately takes the whole window.
private struct WorkRecordPageFrame: ViewModifier {
    let unbounded: Bool

    func body(content: Content) -> some View {
        if unbounded {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.pageFrame()
        }
    }
}

/// A caps eyebrow paired with a hairline rule: the visible header for one
/// section of the receipt document. Static — a heading, never a focus stop.
/// The optional help button is the section's one place for explanation.
private struct SectionHeader: View {
    let title: String
    var help: String? = nil
    let identifier: String

    var body: some View {
        HStack(spacing: Space.m) {
            // A section head outranks the caps field labels in its rows
            // (K126): the card-title role in ink, keeping the hairline.
            HStack(spacing: Space.m) {
                Text(title)
                    .workFont(.titleCard)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("work.section.\(identifier)")
            if let help {
                ContextHelp(title: "About \(title.lowercased())", message: help,
                            identifier: "work.section.\(identifier).help")
            }
        }
    }
}

/// One section of the visible receipt document: a header rule, then its rows.
/// There is no fold — the section's facts are always shown; only a genuinely
/// long list inside uses an `OverflowDisclosure`.
private struct ReceiptSection<Content: View>: View {
    let title: String
    let identifier: String
    var help: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, help: help, identifier: identifier)
                .padding(.bottom, Space.s)
            content()
        }
    }
}

/// The only fold in the document: a quiet, counted trigger that reveals a
/// genuinely long list in place. One level deep — its content never folds
/// again. Muted until hovered (then ink); the chevron carries the affordance
/// and nudges on hover. Internal so the Usage digest can reuse it.
struct OverflowDisclosure<Content: View>: View {
    let label: String
    var identifier: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .workFont(.icon)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .offset(x: hovering && !expanded ? 1 : 0)
                    Text(expanded ? "Show less" : label)
                        .workFont(.captionSemibold)
                }
                .foregroundStyle(hovering || expanded ? Theme.ink : Theme.muted)
                .padding(.vertical, 6).padding(.horizontal, 4)
                .frame(minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SurfaceButtonStyle())
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { hovering = inside }
            }
            .accessibilityLabel(label)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(identifier ?? "work.overflow")
            if expanded { content() }
        }
    }
}

/// A monospaced identifier the reader can copy. The value stays selectable; the
/// copy glyph is always visible and is a keyboard focus stop of its own,
/// turning to a checkmark for 1.5 s with a VoiceOver announcement on copy.
private struct CopyableValue: View {
    let text: String
    /// What was copied, for the tooltip and the announcement ("task ID").
    let announce: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Text(text)
                .workFont(.dataSmall)
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
            // Green is reserved for live connection and external evidence; the
            // checkmark glyph alone says "copied".
            // No control is invisible at rest (K85): the glyph is drawn muted
            // and rises to ink on hover, on focus and after a copy — the same
            // quiet-to-ink grammar as the document's folds. An opacity-0
            // affordance was undiscoverable for a pointer user, and reachable
            // only with Full Keyboard Access, which is off by default.
            IconButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                label: copied ? "Copied \(announce)" : "Copy \(announce)",
                help: "Copy \(announce)",
                tint: hovering || focused || copied ? Theme.ink : Theme.muted,
                action: copy
            )
            .focused($focused)
            Spacer(minLength: 0)
        }
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { hovering = inside }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { copied = true }
        if !SnapshotMode.enabled, let window = NSApp.keyWindow ?? NSApp.mainWindow {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Copied \(announce)",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { copied = false }
        }
    }
}

/// A quiet session row for the Sessions topic: identity and, when already
/// loaded, a step count. Steps themselves live on the activity canvas.
private struct SessionIndexRow: View {
    let member: ReceiptSessionMember
    let preloadedStepCount: Int?
    /// The Task's own title: a session title that only restates it is not
    /// repeated; the row names the session by its client and id instead.
    var taskTitle: String? = nil

    private var label: String {
        if let title = member.title, !title.isEmpty,
           title.caseInsensitiveCompare(taskTitle ?? "") != .orderedSame {
            return title
        }
        return "\(member.client) · \(sessionDistinguishingID(member.clientSessionId))"
    }

    /// One quiet meta line: recording client, kind (only when it qualifies the
    /// row), project when it differs from the task context, and step count
    /// when the session is already loaded.
    private var meta: String {
        var parts = [member.client]
        if member.role == "subagent" { parts.append(member.sessionKind ?? "subagent") }
        if let project = member.project, !project.isEmpty { parts.append("project \(project)") }
        if let count = preloadedStepCount { parts.append("\(count) step\(count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).workFont(.body).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(meta).workFont(.caption).foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(meta)")
    }
}

/// The short, distinguishing tail of an opaque session identity.
func sessionDistinguishingID(_ clientSessionId: String) -> String {
    if let last = clientSessionId.split(separator: ":").last, last.count < clientSessionId.count {
        return String(last)
    }
    return clientSessionId
}

// MARK: - Session drill-down

struct SessionDrillAccessibilityPresentation {
    let title: String
    let distinguishingId: String
    let project: String?
    let role: String?
    let sessionKind: String?
    let expanded: Bool
    let detailSummary: String?
    let loading: Bool
    let failed: Bool
    let lastActivity: String?

    var label: String {
        var parts = [title, "session \(distinguishingId)"]
        if let project = nonempty(project) { parts.append("project \(project)") }
        return parts.joined(separator: ", ")
    }

    var value: String {
        var parts = [expanded ? "Expanded" : "Collapsed"]
        switch role {
        case "subagent": parts.append(nonempty(sessionKind) ?? "subagent")
        case "root": parts.append("root")
        default: parts.append("role unknown")
        }
        if let detailSummary = nonempty(detailSummary) { parts.append(detailSummary) }
        if let lastActivity = nonempty(lastActivity) { parts.append("updated \(lastActivity)") }
        if loading {
            parts.append(failed ? "Retrying session steps" : "Loading session steps")
        } else if failed {
            parts.append("Session steps unavailable")
        }
        return parts.joined(separator: ", ")
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// One session in the drill-down: a header row (role/kind + title) that expands
/// to lazily load `/v1/session` and render its steps — reusing StepCard — and
/// its subagent sessions. Each row owns its own loaded detail (the shared store
/// slot would clobber across several expanded sessions).
struct SessionDrillRow: View {
    let member: ReceiptSessionMember
    let initiallyExpanded: Bool
    @Environment(DashboardStore.self) var dashboard
    @Environment(\.savedWorkReconnect) private var reconnectSavedWork
    @State private var expanded: Bool
    @State private var detail: V1SessionDetail?
    @State private var loading = false
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        member: ReceiptSessionMember,
        initiallyExpanded: Bool = false,
        initiallyLoading: Bool = false,
        initiallyFailed: Bool = false
    ) {
        self.member = member
        self.initiallyExpanded = initiallyExpanded
        _expanded = State(initialValue: initiallyExpanded)
        _loading = State(initialValue: initiallyLoading)
        _failed = State(initialValue: initiallyFailed)
    }

    /// The lazily-loaded detail, or a snapshot-preloaded one. The load guards
    /// use this value so deterministic renderers never start a redundant task.
    private var effectiveDetail: V1SessionDetail? {
        detail ?? dashboard.preloadedSessions["\(member.client)::\(member.clientSessionId)"]
    }

    private var label: String {
        if let title = member.title, !title.isEmpty { return title }
        if let loaded = effectiveDetail?.session.displayTitle, !loaded.isEmpty { return loaded }
        return "\(member.client) · \(distinguishingId)"
    }

    /// Subagent ids share the root's uuid prefix ("<root>:agent-<id>"), so the
    /// DISTINGUISHING part is the component after the last colon — a row list
    /// where every child shows the parent's prefix identifies nothing.
    private var distinguishingId: String {
        let id = member.clientSessionId
        if let last = id.split(separator: ":").last, last.count < id.count {
            return String(last.prefix(16))
        }
        return String(id.prefix(8))
    }

    private var detailSummary: String? {
        guard let detail = effectiveDetail else { return nil }
        let hasChecks = detail.steps.contains { !($0.checks ?? []).isEmpty }
        var parts = ["\(detail.steps.count) step\(detail.steps.count == 1 ? "" : "s")"]
        if hasChecks { parts.append(PayloadAbsence.text(detail.checkTallyText) ?? PayloadAbsence.checks) }
        return parts.joined(separator: " · ")
    }

    private var roleLabel: String {
        switch member.role {
        case "subagent": return member.sessionKind ?? "subagent"
        case "root": return "root"
        default: return "role unknown"
        }
    }

    private var accessibilityPresentation: SessionDrillAccessibilityPresentation {
        SessionDrillAccessibilityPresentation(
            title: label,
            distinguishingId: distinguishingId,
            project: member.project,
            role: member.role,
            sessionKind: member.sessionKind,
            expanded: expanded,
            detailSummary: detailSummary,
            loading: loading,
            failed: failed,
            lastActivity: agoText(member.lastActivityAt)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                if expanded, effectiveDetail == nil, !loading, !failed { Task { await load() } }
            } label: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                            .workFont(.icon)
                            .foregroundStyle(Theme.muted)
                            .workScaledMinFrame(width: 12, height: 18)
                        Text(label)
                            .workFont(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(expanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: expanded)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        if let detailSummary {
                            Text(detailSummary)
                                .workFont(.dataSmall)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    HStack(spacing: 8) {
                        Chip(
                            text: roleLabel,
                            tint: member.role == "root" ? Theme.accent : Theme.muted
                        )
                        if let project = member.project, member.role == "root" {
                            Text(project).workFont(.caption).foregroundStyle(Theme.muted)
                        }
                        if let ago = agoText(member.lastActivityAt) {
                            Text(ago).workFont(.dataSmall).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.leading, 18)
                }
                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(SurfaceButtonStyle(focusInset: 2))
            // NOT `.accessibilityElement(children: .ignore)`: a Button already
            // speaks as ONE element, and that modifier REPLACES it — the
            // control loses its button role and its press action with it
            // (K118). The label below is simply what the button says.
            .accessibilityLabel(accessibilityPresentation.label)
            .accessibilityValue(accessibilityPresentation.value)
            .accessibilityHint(expanded ? "Hides session steps" : "Shows session steps")

            if expanded {
                expandedBody
                    .padding(.horizontal, 12).padding(.bottom, 10).padding(.leading, 6)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.contentUpdate, value: expanded)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius).strokeBorder(Theme.cardLine, lineWidth: Metrics.borderW))
        .task {
            // The root session opens expanded — its step-by-step is the point;
            // load its steps up front.
            if expanded, effectiveDetail == nil, !loading, !failed { await load() }
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let detail = effectiveDetail {
            VStack(alignment: .leading, spacing: 6) {
                if let savedAt = dashboard.sessionSavedAt(client: member.client, sessionID: member.clientSessionId) {
                    Text("Session copy saved: \(savedAt.ISO8601Format())")
                        .workFont(.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                if detail.steps.isEmpty {
                    Text("No recorded steps are linked to this session.")
                        .workFont(.caption)
                        .foregroundStyle(Theme.muted)
                } else {
                    let stepItems = SessionStepItem.make(detail.steps)
                    // A snapshot opens the first couple of check-bearing steps
                    // (so their check evidence — command + exit code — shows) plus
                    // one un-checked step (so an honest "no passing check" step is
                    // visible too); the live app opens every step collapsed.
                    let opened: Set<String> = SnapshotMode.enabled
                        ? Set(
                            stepItems.filter { !($0.step.checks?.isEmpty ?? true) }.prefix(2).map(\.id)
                            + stepItems.filter { ($0.step.checks?.isEmpty ?? true) }.prefix(1).map(\.id)
                          )
                        : []
                    ScrollContentStack(alignment: .leading, spacing: 6) {
                        ForEach(stepItems) { item in
                            StepCard(
                                step: item.step,
                                initiallyExpanded: opened.contains(item.id),
                                accessibilityContext: item.id
                            )
                        }
                    }
                }
                // The Task's subagents are already listed once, flat and
                // expandable, as sibling SessionDrillRows in this group's member
                // list. Re-listing this session's descendants here showed the
                // same subagents a second time (a confusing "41 and 41"), so the
                // member list is the single source of truth for the tree.
            }
        } else if dashboard.isOfflineSnapshot {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("This session detail was not saved on this Mac. Reconnect the recorder to load it.")
                    .workFont(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Metrics.readingMeasure, alignment: .leading)
                if let reconnectSavedWork {
                    Button("Back to recovery", action: reconnectSavedWork)
                        .buttonStyle(QuietButtonStyle(horizontalPadding: 8))
                }
            }
        } else if failed {
            HStack(spacing: Space.s) {
                Text(loading ? "Retrying session steps…" : "Session steps couldn't be loaded.")
                    .workFont(.caption)
                    .foregroundStyle(Theme.muted)
                Button {
                    if !loading { Task { await load() } }
                } label: {
                    Text(loading ? "Retrying…" : "Retry")
                        .workFont(.captionSemibold)
                        .frame(
                            minWidth: ButtonFeedback.minimumHitDimension,
                            minHeight: ButtonFeedback.minimumHitDimension
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(SurfaceButtonStyle(focusInset: 2))
                .disabled(loading)
                .accessibilityHint(loading ? "Retry is in progress" : "Loads this session's steps again")
            }
        } else if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading session steps…").workFont(.caption).foregroundStyle(Theme.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading session steps")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            detail = try await dashboard.loadSession(client: member.client, sessionId: member.clientSessionId)
            failed = false
        } catch {
            failed = true
        }
    }
}
