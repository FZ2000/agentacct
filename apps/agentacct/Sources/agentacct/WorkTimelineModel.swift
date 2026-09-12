import Foundation

/// A read-only projection. Ordering, shared files and session lineage never
/// create a causal edge or upgrade the result/source supplied by the receipt.
struct WorkTimelineRecord: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case step, check, activity }
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
    var sectionRecordIDs: [String] = []
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

    var newestRecord: WorkTimelineRecord? {
        records.filter { $0.latestTime != nil }.max {
            if $0.latestTime == $1.latestTime { return $0.id < $1.id }
            return $0.latestTime! < $1.latestTime!
        }
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

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 253_402_300_800 else { return nil }
        return value
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
