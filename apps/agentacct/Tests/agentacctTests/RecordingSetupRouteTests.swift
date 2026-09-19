import XCTest
@testable import agentacct

@MainActor
final class RecordingSetupRouteTests: XCTestCase {
    func testReachableRecorderWithStoppedOrStaleWatcherOpensRecorderRecovery() throws {
        let glance = try JSONDecoder().decode(Glance.self, from: Data("""
        {"schema":"agentacct.glance.v1","usage":{"windows":[]},"limits":[],"plan":[],"recent_sessions":[]}
        """.utf8))
        for state in ["stopped", "stale", "running"] {
            let issues: [V1IngestionIssue] = state == "running"
                ? [.init(code: "watcher_stale", source: nil, action: "Inspect the watcher heartbeat")]
                : []
            let snapshot = RecordingHealthSnapshot.project(
                glancePhase: .connected(.init(glance: glance, daemonVersion: "test")),
                setupPhase: .done,
                ingestion: .init(state: "degraded", lastSuccessAt: 100, sources: [],
                                 watcher: .init(state: state, intervalSeconds: 30, heartbeatAt: 100), issues: issues),
                ingestionError: nil
            )
            let watcher = try XCTUnwrap(snapshot.causes.first { $0.id == "ingestion:watcher" })
            XCTAssertFalse(snapshot.causes.contains { $0.scope == .endpoint })
            XCTAssertEqual(route(causes: snapshot.causes), .connection(reason: watcher.detail), state)
            XCTAssertEqual(route(selected: watcher, causes: snapshot.causes), .connection(reason: watcher.detail), state)
        }
    }

    func testExplicitCauseKeepsItsExplanationWhenAnotherFailureHasHigherDefaultPriority() {
        let watcher = cause("ingestion:watcher", scope: .ingestion, detail: "The selected watcher is stopped.")
        let endpoint = cause("endpoint:unreachable", scope: .endpoint, detail: "The endpoint also stopped responding.")

        XCTAssertEqual(route(selected: watcher, causes: [endpoint, watcher]), .connection(reason: watcher.detail))
        XCTAssertEqual(route(causes: [watcher, endpoint]), .connection(reason: endpoint.detail))
        XCTAssertEqual(route(causes: [watcher]), .connection(reason: watcher.detail))
    }

    func testInterruptedSynchronizationTakesPriorityAndPendingSynchronizationDoesNotReconnect() {
        let watcher = cause("ingestion:watcher", scope: .ingestion)
        XCTAssertEqual(
            RecordingSetupRoute.project(selectedCause: watcher, currentCauses: [watcher], setupPhase: .failed("A protected transaction needs recovery."), synchronizationFinished: false),
            .synchronization(reason: "A protected transaction needs recovery.")
        )
        XCTAssertEqual(
            RecordingSetupRoute.project(selectedCause: watcher, currentCauses: [watcher], setupPhase: .working("Checking the installation"), synchronizationFinished: false),
            .configuration
        )
    }

    func testUnrelatedSourceFaultsAndFailedClientSetupDoNotBecomeRecorderOnlyRecovery() {
        let source = cause("ingestion:source_read_permission_required:codex", scope: .ingestion, action: .sources)
        let unknown = cause("ingestion:future_fault", scope: .ingestion)
        let wrongScope = cause("ingestion:watcher", scope: .setup)
        let clientSetup = cause("setup:failed", scope: .setup)
        let endpoint = cause("endpoint:unreachable", scope: .endpoint)
        for selected in [source, unknown, wrongScope, clientSetup] {
            XCTAssertEqual(route(selected: selected, causes: [endpoint, selected]), .configuration)
        }
        XCTAssertEqual(route(causes: [source, unknown, wrongScope]), .configuration)
        XCTAssertEqual(
            RecordingSetupRoute.project(selectedCause: clientSetup, currentCauses: [clientSetup], setupPhase: .failed("Client merge stopped."), synchronizationFinished: true),
            .configuration
        )
    }

    func testRecoveredNoticeDoesNotReintroduceItsPreviousWatcherFault() {
        let watcher = cause("ingestion:watcher", scope: .ingestion)
        var notice = RecordingHealthNotice(id: "watcher-episode", cause: watcher, observedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(route(selected: notice.actionableCause, causes: []), .connection(reason: watcher.detail))
        notice.dismissed = true
        XCTAssertEqual(notice.actionableCause, watcher, "Dismissal does not establish recovery.")
        notice.recoveredAt = Date(timeIntervalSince1970: 200)

        XCTAssertNil(notice.actionableCause)
        XCTAssertEqual(route(selected: notice.actionableCause, causes: []), .configuration)
    }

    func testVersionMismatchRemainsAConnectionRouteAndNoFaultOpensConfiguration() {
        let incompatible = cause("endpoint:incompatible", scope: .endpoint, detail: "The API schema is incompatible.")
        XCTAssertEqual(route(causes: [incompatible]), .connection(reason: incompatible.detail))
        XCTAssertEqual(route(causes: []), .configuration)
    }

    private func route(selected: RecordingHealthCause? = nil, causes: [RecordingHealthCause]) -> RecordingSetupRoute {
        RecordingSetupRoute.project(selectedCause: selected, currentCauses: causes, setupPhase: .done, synchronizationFinished: true)
    }

    private func cause(_ id: String, scope: RecordingHealthScope, detail: String = "Original reported explanation.", action: RecordingHealthAction = .setup) -> RecordingHealthCause {
        .init(id: id, scope: scope, title: "Reported issue", detail: detail, tone: .caution, action: action, affectedSources: [], recoveryDetail: "The check recovered.")
    }
}
