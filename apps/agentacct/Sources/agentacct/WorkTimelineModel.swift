import Foundation

/// A read-only projection. Ordering, shared files and session lineage never
/// create a causal edge or upgrade the result/source supplied by the receipt.
struct WorkTimelineRecord: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case step, check }
    var id: String
    var eventID: String? = nil
    var laneID: String
    var laneTitle: String
    var lineage: String
    var kind: Kind
    var title: String
    var start: Double? = nil
    var end: Double? = nil
    var timeNote: String = "Source time unavailable"
    var timeWarning: String? = nil
    var result: String = "unknown"
    var source: String = "Source unavailable"
    var scope: String? = nil
    var summary: String? = nil
    var files: [String] = []
    var exitCode: Int? = nil
    var superseded: Bool = false
    var supersededBy: String? = nil
    var sectionRecordID: String? = nil
    var resolution: String? = nil
    var resolutionScope: String? = nil
    var artifact: String? = nil
    var artifactPath: String? = nil
    var artifactURL: String? = nil
    var artifactPathRedacted: Bool? = nil
    var artifactURLRedacted: Bool? = nil
    var commandRedacted: Bool = false
    var identityNote: String? = nil
    var disposition: String? = nil
    var sectionTitle: String? = nil

    var isCurrentFailure: Bool {
        kind == .check && !superseded && disposition == nil && ["failed", "error"].contains(result)
    }
    var isDuration: Bool { start != nil && end != nil && end! > start! }
    var latestTime: Double? { end ?? start }
    var resolutionDescription: String? {
        if kind == .step { return resolution }
        guard resolution != nil || resolutionScope != nil else { return nil }
        return "Reported resolution (\(resolutionScope ?? "scope not supplied")): \(resolution ?? "summary not supplied")"
    }
    var artifactDescriptions: [String] {
        [artifact.map { "Artifact reference: \($0)" },
         artifactPathRedacted == true ? "Artifact path intentionally not captured." : artifactPath.map { "Artifact path: \($0)" },
         artifactURLRedacted == true ? "Artifact URL intentionally not captured." : artifactURL.map { "Artifact URL: \($0)" }]
            .compactMap { $0 }
    }
    var resultLabel: String {
        let label = result.replacingOccurrences(of: "_", with: " ").capitalized
        return kind == .step ? "Reported \(label.lowercased())" : label
    }
    var searchableText: String {
        ([title, sectionTitle ?? "", laneID, laneTitle, lineage, source, result, scope ?? "", summary ?? "", eventID ?? ""] + files)
            .joined(separator: " ")
    }
}

struct WorkTimelineLane: Identifiable, Equatable {
    var id: String
    var title: String
    var lineage: String
    var availability: String
}

struct WorkTimelineProjection: Equatable {
    var records: [WorkTimelineRecord]
    var lanes: [WorkTimelineLane]
    var notices: [String]

    static let empty = WorkTimelineProjection(records: [], lanes: [], notices: [])

    init(records: [WorkTimelineRecord], lanes: [WorkTimelineLane] = [], notices: [String] = []) {
        // Only immutable event IDs authorize deduplication. Anonymous rows with
        // identical text remain separate: sameness of text is not event identity.
        var events = Set<String>()
        self.records = records.filter { record in
            guard let eventID = record.eventID else { return true }
            return events.insert(eventID).inserted
        }.sorted(by: Self.chronological)
        self.lanes = lanes
        self.notices = notices
    }

    func displayedOrder(_ filtered: [WorkTimelineRecord], mode: String) -> [WorkTimelineRecord] {
        guard mode == "timeline" else { return filtered }
        return lanes.flatMap { lane in filtered.filter { $0.laneID == lane.id && $0.start != nil } }
            + filtered.filter { $0.start == nil }
    }

    var newestRecord: WorkTimelineRecord? {
        records.filter { $0.latestTime != nil }.max {
            if $0.latestTime == $1.latestTime { return $0.id < $1.id }
            return $0.latestTime! < $1.latestTime!
        }
    }

    init(receipt: Receipt, sessions: [String: V1SessionDetail], errors: [String: String] = [:]) {
        var records: [WorkTimelineRecord] = []
        var lanes: [WorkTimelineLane] = []
        var notices: [String] = []
        var seenLanes = Set<String>()
        for group in receipt.sessions ?? [] {
            for member in group.members where seenLanes.insert(member.id).inserted {
                let title = Self.nonempty(member.title) ?? "\(member.client) · \(member.clientSessionId.prefix(8))"
                var lineage: String
                if member.id == group.root.sessionKey {
                    lineage = "\(group.role == "continuation" ? "Continuation" : "Root") session · \(group.lineageState ?? "lineage state unavailable")"
                } else {
                    lineage = "\(member.role ?? "Member") of \(group.root.client) · \(group.root.clientSessionId.prefix(8)) · session relationship"
                }
                let distinguishingID = member.clientSessionId.split(separator: ":").last.map { String($0.prefix(16)) } ?? member.clientSessionId
                lineage += " · ID \(distinguishingID)"
                let detail = sessions[member.id]
                lanes.append(WorkTimelineLane(
                    id: member.id, title: title, lineage: lineage,
                    availability: errors[member.id].map { detail == nil ? "Unavailable: \($0)" : "Refresh failed; retained data: \($0)" }
                        ?? (detail == nil ? "Session details not loaded" : "\(detail!.steps.count) recorded steps")
                ))
                guard let detail else { continue }
                // A response for another session cannot populate this lane.
                guard detail.session.client == member.client,
                      detail.session.clientSessionId == member.clientSessionId else {
                    notices.append("Session identity did not match \(title); its records were not joined.")
                    continue
                }
                for item in SessionStepItem.make(detail.steps) {
                    let step = item.step
                    let stepID = "session:\(member.id)/\(item.id)"
                    let bounds = Self.stepBounds(start: step.startedAt, update: step.updatedAt)
                    records.append(WorkTimelineRecord(
                        id: stepID, laneID: member.id, laneTitle: title, lineage: lineage, kind: .step,
                        title: Self.nonempty(step.title) ?? "Unnamed work section",
                        start: bounds.start, end: bounds.end, timeNote: bounds.note, timeWarning: bounds.warning,
                        result: step.latestStatus ?? "unknown", source: "Agent section report",
                        scope: step.sectionId ?? step.workId, summary: step.summary,
                        files: Self.exactFiles(step.files), resolution: step.blocker.map { "Reported blocker: \($0)" },
                        identityNote: step.workId == nil && step.sectionId == nil ? "No stable section identity; local content identity is used." : nil
                    ))
                    for checkItem in StepCheckDigest(checks: step.checks ?? []).all {
                        let check = checkItem.check
                        let eventID = Self.nonempty(check.eventId)
                        let time = Self.validTime(check.createdAt)
                        records.append(WorkTimelineRecord(
                            id: eventID.map { "event:\($0)" } ?? "\(stepID)/check:\(checkItem.id)",
                            eventID: eventID, laneID: member.id, laneTitle: title, lineage: lineage,
                            kind: .check, title: Self.nonempty(check.evidenceType)?.capitalized ?? "Machine check",
                            start: time, timeNote: time == nil ? "Source time unavailable" : "Recorded check point; duration unavailable",
                            result: check.result ?? "unknown", source: Self.sourceLabel(check.sourceType),
                            scope: check.checkIdentity, summary: check.summary, files: Self.exactFiles(check.files),
                            exitCode: check.exitCode, superseded: checkItem.isHistory,
                            supersededBy: Self.nonempty(check.supersededByEventId), sectionRecordID: stepID,
                            resolution: check.resolutionSummary,
                            resolutionScope: check.resolutionScope,
                            artifact: check.artifactRef, artifactPath: check.artifactPath, artifactURL: check.artifactUrl,
                            artifactPathRedacted: check.artifactPathRedacted, artifactURLRedacted: check.artifactUrlRedacted,
                            commandRedacted: check.commandRedacted == true,
                            identityNote: eventID == nil ? "No event ID; this row cannot be deduplicated across receipt and session views." : nil,
                            sectionTitle: step.title
                        ))
                    }
                }
            }
        }
        let checkRows = ReceiptCheckCollectionPresentation(evidence: receipt.dimensions.evidence)
        if !checkRows.rows.isEmpty {
            let laneID = "task:\(receipt.taskId)"
            lanes.append(WorkTimelineLane(id: laneID, title: "Task check evidence", lineage: "Session attribution unavailable in receipt", availability: "\(checkRows.rows.count) itemized receipt checks"))
            for row in checkRows.rows {
                let check = row.check
                let time = Self.validTime(check.at)
                let disposition = check.finding?.attentionOpen == false
                    ? (check.finding?.state ?? "attention closed")
                    : check.finding?.state.flatMap { $0 == "open" ? nil : $0 }
                records.append(WorkTimelineRecord(
                    id: "\(laneID)/receipt:\(row.id)", laneID: laneID, laneTitle: "Task check evidence",
                    lineage: "Session attribution unavailable in receipt", kind: .check,
                    title: row.title, start: time,
                    timeNote: time == nil ? "Source time unavailable" : "Recorded check point; duration unavailable",
                    result: check.result ?? "unknown", source: Self.sourceLabel(check.source), scope: check.scope,
                    summary: check.summary, files: Self.exactFiles(check.files), exitCode: check.exitCode,
                    superseded: check.superseded == true, artifact: check.artifactRef, artifactURL: check.artifactUrl,
                    commandRedacted: check.commandRedacted == true,
                    identityNote: "Receipt omits event identity. This entry may also appear in a session; no automatic join is assumed.",
                    disposition: disposition
                ))
            }
            notices.append("Receipt checks have no event/session IDs and may also appear in session evidence. Counts describe displayed records, not unique check runs.")
        }
        if let note = checkRows.aggregateNotice { notices.append(note) }
        if let note = checkRows.itemizedNotice { notices.append(note) }
        if lanes.isEmpty { notices.append("No session members or itemized checks are available for this task.") }
        self.init(records: records, lanes: lanes, notices: notices)
    }

    var interval: WorkTimelineInterval? {
        let times = records.flatMap { [$0.start, $0.end].compactMap { $0 } }
        guard let lower = times.min(), let upper = times.max() else { return nil }
        let padding = max((upper - lower) * 0.03, 1)
        return WorkTimelineInterval(lower: lower - padding, upper: upper + padding)
    }

    static func chronological(_ lhs: WorkTimelineRecord, _ rhs: WorkTimelineRecord) -> Bool {
        if lhs.start != rhs.start { return (lhs.start ?? .infinity) < (rhs.start ?? .infinity) }
        return lhs.id < rhs.id
    }

    static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 253_402_300_800 else { return nil }
        return value
    }

    static func stepBounds(start: Double?, update: Double?) -> (start: Double?, end: Double?, note: String, warning: String?) {
        let first = validTime(start), last = validTime(update)
        if let first, let last, last > first {
            return (first, last, "Recorded section start → latest update; not execution duration", nil)
        }
        if let first, let last, last < first {
            return (first, nil, "Update precedes start; clock order is inconsistent. Duration unavailable.", "The recorded update precedes the start. Timing is inconsistent.")
        }
        if let point = last ?? first { return (point, nil, "Recorded section point; duration unavailable", nil) }
        return (nil, nil, "Source time unavailable", nil)
    }

    static func exactFiles(_ files: [String]?) -> [String] {
        Array(Set((files ?? []).filter { !$0.isEmpty })).sorted()
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func sourceLabel(_ source: String?) -> String {
        switch source {
        case "ci": return "CI source"
        case "external", "provider": return "External source: \(source!)"
        case "client_hook", "hook": return "Client hook"
        case "mcp", "agent_report", "agent": return "Agent-reported check"
        case nil: return "Source unavailable"
        default: return source!.replacingOccurrences(of: "_", with: " ")
        }
    }

    func relationship(_ first: WorkTimelineRecord, _ second: WorkTimelineRecord) -> String {
        if first.supersededBy != nil && first.supersededBy == second.eventID { return "Recorded supersession: first record → second record." }
        if second.supersededBy != nil && second.supersededBy == first.eventID { return "Recorded supersession: second record → first record." }
        if first.sectionRecordID == second.id || second.sectionRecordID == first.id { return "Recorded section membership." }
        return "No direct event relationship is supplied. Shared time, files or session lineage do not establish causality."
    }
}

struct WorkTimelineInterval: Equatable, Codable {
    var lower: Double
    var upper: Double
    var span: Double { max(upper - lower, 1) }
    func contains(_ record: WorkTimelineRecord) -> Bool {
        guard let start = record.start else { return true }
        return start <= upper && (record.end ?? start) >= lower
    }
    func fraction(_ time: Double) -> Double { min(max((time - lower) / span, 0), 1) }
}

/// Synthesized decoding ignores retired comparison keys in saved bookmarks,
/// retaining the user's filters, selection and history without reviving that UI.
struct WorkTimelineBookmark: Equatable, Codable {
    var selectedID: String? = nil
    var query = ""
    var file: String? = nil
    var failuresOnly = false
    var mode = "timeline"
    var interval: WorkTimelineInterval? = nil
    var anchorID: String? = nil
    var scrollOffsets: [WorkTimelineScrollOffset]? = nil
    var overviewExpanded: Bool? = nil
    var previousFileFilters: WorkTimelineFilterContext? = nil
}

struct WorkTimelineFilterContext: Equatable, Codable {
    var query: String
    var file: String?
    var failuresOnly: Bool
    var interval: WorkTimelineInterval?
}

struct WorkTimelineNavigation: Equatable, Codable {
    var view = WorkTimelineBookmark()
    var following = true
    var history: WorkTimelineBookmark? = nil

    mutating func showFile(_ file: String) {
        if view.previousFileFilters == nil {
            view.previousFileFilters = .init(query: view.query, file: view.file, failuresOnly: view.failuresOnly, interval: view.interval)
        }
        following = false
        view.file = file
        view.query = ""
        view.failuresOnly = false
        view.interval = nil
    }

    mutating func leaveFile() {
        if let previous = view.previousFileFilters {
            view.query = previous.query; view.file = previous.file
            view.failuresOnly = previous.failuresOnly; view.interval = previous.interval
        } else { view.file = nil }
        view.previousFileFilters = nil
        following = false
    }

    mutating func beginArrivals() {
        if history == nil { history = view }
        following = false
        view.query = ""
        view.file = nil
        view.failuresOnly = false
    }
    /// A bookmark can survive an app restart even when its held snapshot cannot.
    /// Restore the original investigation, never pretend current data is that
    /// earlier snapshot or keep an empty arrivals-only view.
    @discardableResult
    mutating func restorePositionWithoutSnapshot() -> Bool {
        let wasInvestigating = !following || history != nil
        if let history { view = history; self.history = nil }
        if wasInvestigating { following = false }
        return wasInvestigating
    }

    mutating func returnToHistory() {
        guard let history else { return }
        view = history
        self.history = nil
        following = false
    }
}

/// A held snapshot does not mutate records under a selected/dragged view.
/// Pending revisions are counted once by identity, including late source-time
/// arrivals. The current polling API has no ingestion cursor, so this claims
/// snapshot observation only, never lossless event streaming.
struct WorkTimelineFeed {
    var visible = WorkTimelineProjection.empty
    var latest = WorkTimelineProjection.empty
    private(set) var initialized = false
    private(set) var historySnapshot: WorkTimelineProjection?
    private(set) var arrivalIDs: Set<String> = []
    private(set) var removedArrivalCount = 0

    var pendingIDs: Set<String> {
        let existing = Dictionary(visible.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = Dictionary(latest.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(incoming.keys.filter { existing[$0] != incoming[$0] })
            .union(Set(existing.keys).subtracting(incoming.keys))
    }

    mutating func ingest(_ projection: WorkTimelineProjection, following: Bool) {
        latest = projection
        if following || !initialized { visible = projection }
        initialized = true
    }

    mutating func reveal() { visible = latest }

    mutating func reviewArrivals() {
        if historySnapshot == nil { historySnapshot = visible }
        arrivalIDs = pendingIDs
        let available = Set(latest.records.map(\.id))
        removedArrivalCount = arrivalIDs.subtracting(available).count
        visible = latest
    }

    mutating func restoreHistory() {
        if let historySnapshot { visible = historySnapshot }
        historySnapshot = nil
        arrivalIDs = []
        removedArrivalCount = 0
    }
}
