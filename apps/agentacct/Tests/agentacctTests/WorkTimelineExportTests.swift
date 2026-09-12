import XCTest
@testable import agentacct

final class WorkTimelineExportTests: XCTestCase {
    func testComparisonRetainsFullSessionIdentitiesAndLabelsEvidenceOutsideFilters() {
        let first = WorkTimelineRecord(id: "event:first", laneID: "codex::same-prefix-0001", laneTitle: "Review parser",
            lineage: "Root session", kind: .check, title: "Test parser", result: "failed", source: "Client hook")
        let second = WorkTimelineRecord(id: "event:second", laneID: "codex::same-prefix-0002", laneTitle: "Review parser",
            lineage: "Root session", kind: .check, title: "Test parser", result: "passed", source: "Client hook")
        let projection = WorkTimelineProjection(records: [first, second])
        let output = WorkTimelineExport.text(taskID: "task", title: nil, records: [first], projection: projection,
            following: false, query: "", file: nil, generatedAt: Date(timeIntervalSince1970: 1_000),
            comparisonIDs: [first.id, second.id])
        XCTAssertTrue(output.contains("Evidence lane identity: codex::same-prefix-0001"))
        XCTAssertTrue(output.contains("Evidence lane identity: codex::same-prefix-0002"))
        XCTAssertTrue(output.contains("Slot A: event:first"))
        XCTAssertTrue(output.contains("Slot B: event:second"))
        XCTAssertTrue(output.contains("Relationship: " + projection.relationship(first, second)))
        XCTAssertTrue(output.contains("1 selected comparison record falls outside the displayed filters"))
        XCTAssertTrue(output.contains("Comparison-only record: event:second"))
        XCTAssertFalse(output.contains("Displayed record: event:second"))
    }

    func testUnavailableComparisonIsExplicitAndDoesNotInventEvidence() {
        let output = WorkTimelineExport.text(taskID: "task", title: nil, records: [], projection: .init(records: []),
            following: false, query: "", file: nil, generatedAt: Date(timeIntervalSince1970: 1_000),
            comparisonIDs: ["", "missing-record"])
        XCTAssertTrue(output.contains("Slot A: not selected"))
        XCTAssertTrue(output.contains("Slot B: missing-record (unavailable in this snapshot)"))
        XCTAssertFalse(output.contains("Relationship:"))
        XCTAssertFalse(output.contains("Comparison-only record:"))
    }

    func testExportKeepsPartialResolutionAllArtifactLocatorsAndSourcePrecision() {
        let time = 1_700_000_000.123456
        let record = WorkTimelineRecord(id: "check", laneID: "codex::session", laneTitle: "Review",
            lineage: "Root session", kind: .check, title: "Verify", start: time, result: "failed",
            resolution: "One case fixed", resolutionScope: "partial", artifact: "report-ref",
            artifactPath: "reports/check.json", artifactURL: "https://example.test/check")
        let output = WorkTimelineExport.text(taskID: "task", title: nil, records: [record],
            projection: .init(records: [record]), following: false, query: "", file: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertTrue(output.contains("Reported resolution (partial): One case fixed"))
        XCTAssertTrue(output.contains("Artifact reference: report-ref"))
        XCTAssertTrue(output.contains("Artifact path: reports/check.json"))
        XCTAssertTrue(output.contains("Artifact URL: https://example.test/check"))
        XCTAssertTrue(output.contains(String(time)))
        XCTAssertTrue(output.contains("2023-11-14T22:13:20.123Z"))
        XCTAssertTrue(record.isCurrentFailure, "A partial reported resolution cannot silently clear failure")
    }

    func testRedactedArtifactsDoNotLeakIntoExportAndStepBlockersKeepTheirMeaning() {
        let record = WorkTimelineRecord(id: "check", laneID: "lane", laneTitle: "Review",
            lineage: "Root", kind: .check, title: "Verify", artifactPath: "private-path",
            artifactURL: "private-url", artifactPathRedacted: true, artifactURLRedacted: true)
        let output = WorkTimelineExport.text(taskID: "task", title: nil, records: [record],
            projection: .init(records: [record]), following: false, query: "", file: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertFalse(output.contains("private-path"))
        XCTAssertFalse(output.contains("private-url"))
        XCTAssertTrue(output.contains("Artifact path intentionally not captured"))
        XCTAssertTrue(output.contains("Artifact URL intentionally not captured"))
        var step = record
        step.kind = .step
        step.resolution = "Blocked: credentials unavailable"
        XCTAssertEqual(step.resolutionDescription, "Blocked: credentials unavailable")
    }

    func testExportPreservesUnknownFieldsFailureAndHeldScope() {
        let failed = WorkTimelineRecord(id: "check-a", laneID: "codex::session-a", laneTitle: "Review",
            lineage: "Root session", kind: .check, title: "Test", result: "failed", source: "Agent-reported check",
            identityNote: "No immutable event identity")
        let other = WorkTimelineRecord(id: "check-b", laneID: "codex::session-b", laneTitle: "Other",
            lineage: "Child session", kind: .check, title: "Hidden record")
        let output = WorkTimelineExport.text(taskID: "task", title: "Task", records: [failed],
            projection: .init(records: [failed, other], notices: ["Some sessions are unavailable"]),
            following: false, query: "Test", file: nil, generatedAt: Date(timeIntervalSince1970: 1_000),
            failuresOnly: true, interval: .init(lower: 100, upper: 200),
            outcome: "open_finding", handoff: "Handed off; review the failing check")
        XCTAssertTrue(output.contains("held for review"))
        XCTAssertTrue(output.contains("Current failures filter: on"))
        XCTAssertTrue(output.contains("Time range: 1970-01-01T00:01:40Z to 1970-01-01T00:03:20Z"))
        XCTAssertTrue(output.contains("Undated records remain included"))
        XCTAssertTrue(output.contains("1 displayed record of 2 loaded records"))
        XCTAssertTrue(output.contains("Recorded at: unknown"))
        XCTAssertTrue(output.contains("Result: Failed"))
        XCTAssertTrue(output.contains("Agent-reported check"))
        XCTAssertTrue(output.contains("Handed off; review the failing check"))
        XCTAssertTrue(output.contains("Some sessions are unavailable"))
        XCTAssertFalse(output.contains("Hidden record"))
        XCTAssertFalse(output.contains("$0"))
    }
}
