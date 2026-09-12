import XCTest
@testable import agentacct

@MainActor
final class SetupCaptureLookupTests: XCTestCase {
    private let boundary = Date(timeIntervalSince1970: 1_000)

    func testMissingFirstDetailDoesNotPreventLaterFreshCapture() async throws {
        let rows = [session("missing"), session("fresh")]
        var loaded: [String] = []
        let result = try await SetupCaptureLookup.scan(client: .codex, after: boundary,
            loadPage: { _, offset in try self.page(rows, offset: offset, truncated: false) },
            loadDetail: { id in
                loaded.append(id)
                if id == "missing" { throw GlanceClientError.http(404) }
                return try self.detail(id, eventID: "evt-fresh", at: 1_001)
            })

        XCTAssertEqual(loaded, ["missing", "fresh"])
        XCTAssertEqual(result.capture?.eventID, "evt-fresh")
        XCTAssertEqual(result.capture?.exactSessionKey, "codex::fresh")
    }

    func testRotatingCursorEventuallyChecksCandidateThirteen() async throws {
        let rows = (1...14).map { session("session-\($0)") }
        var loaded: [String] = []
        let loadPage: (Int, Int) async throws -> V1SessionsPayload = { limit, offset in
            try self.page(Array(rows.dropFirst(offset).prefix(limit)), offset: offset, truncated: offset + limit < rows.count)
        }
        let loadDetail: (String) async throws -> V1SessionDetail = { id in
            loaded.append(id)
            return try self.detail(id, eventID: "evt-\(id)", at: id == "session-13" ? 1_001 : 999)
        }
        let first = try await SetupCaptureLookup.scan(client: .codex, after: boundary, loadPage: loadPage, loadDetail: loadDetail)
        XCTAssertNil(first.capture)
        XCTAssertEqual(first.nextCursor.offset, 12)
        XCTAssertEqual(loaded.count, 12)

        let second = try await SetupCaptureLookup.scan(client: .codex, after: boundary, cursor: first.nextCursor, loadPage: loadPage, loadDetail: loadDetail)

        XCTAssertEqual(second.capture?.eventID, "evt-session-13")
        XCTAssertEqual(loaded.last, "session-13")
        XCTAssertEqual(loaded.count, 13)
    }

    func testOlderDaemonUnfilteredPagesCannotStarveTargetClient() async throws {
        let rows = [session("other-1", client: "claude-code"), session("other-2", client: "hermes"), session("target")]
        var offsets: [Int] = []
        var loaded: [String] = []
        let result = try await SetupCaptureLookup.scan(client: .codex, after: boundary, pageSize: 2,
            loadPage: { limit, offset in
                offsets.append(offset)
                return try self.page(Array(rows.dropFirst(offset).prefix(limit)), offset: offset, truncated: offset + limit < rows.count)
            }, loadDetail: { id in
                loaded.append(id)
                return try self.detail(id, eventID: "evt-target", at: 1_001)
            })

        XCTAssertEqual(offsets, [0, 2])
        XCTAssertEqual(loaded, ["target"])
        XCTAssertEqual(result.capture?.clientID, "codex")
    }

    func testDetailCancellationIsPropagatedWithoutTryingAnotherCandidate() async throws {
        let cancellations: [Error] = [CancellationError(), URLError(.cancelled)]
        for cancellation in cancellations {
            var loaded = 0
            do {
                _ = try await SetupCaptureLookup.scan(client: .codex, after: boundary,
                    loadPage: { _, offset in try self.page([self.session("first"), self.session("second")], offset: offset, truncated: false) },
                    loadDetail: { _ in loaded += 1; throw cancellation })
                XCTFail("Cancellation must propagate")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            XCTAssertEqual(loaded, 1)
        }
    }

    func testTaskCancellationAfterDetailResponseCannotConfirmCapture() async throws {
        let task = Task {
            try await SetupCaptureLookup.scan(client: .codex, after: boundary,
                loadPage: { _, offset in try self.page([self.session("fresh")], offset: offset, truncated: false) },
                loadDetail: { id in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try self.detail(id, eventID: "evt-after-cancel", at: 1_001)
                })
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled scan must not supply capture")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExactClientSessionKeysAndFreshIdentifiedEventRemainRequired() async throws {
        let rows = [
            session("bad-row-key", key: "codex::unrelated"), session("wrong-client"),
            session("wrong-session"), session("bad-detail-key"), session("old-event"), session("unnamed-event"), session("valid")
        ]
        var loaded: [String] = []
        let result = try await SetupCaptureLookup.scan(client: .codex, after: boundary,
            loadPage: { _, offset in try self.page(rows, offset: offset, truncated: false) },
            loadDetail: { id in
                loaded.append(id)
                switch id {
                case "wrong-client": return try self.detail(id, client: "claude-code", eventID: "evt-other-client", at: 1_010)
                case "wrong-session": return try self.detail("another-session", eventID: "evt-other-session", at: 1_010)
                case "bad-detail-key": return try self.detail(id, key: "codex::unrelated", eventID: "evt-inconsistent", at: 1_010)
                case "old-event": return try self.detail(id, eventID: "evt-old", at: 1_000)
                case "unnamed-event": return try self.detail(id, eventID: nil, at: 1_010)
                default: return try self.detail(id, eventID: "evt-valid", at: 1_001)
                }
            })

        XCTAssertFalse(loaded.contains("bad-row-key"))
        XCTAssertEqual(result.capture?.eventID, "evt-valid")
        XCTAssertEqual(result.capture?.observedAt, Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(result.capture?.exactSessionKey, "codex::valid")
    }

    func testListFailurePropagatesWithoutFetchingDetails() async {
        var loaded = false
        do {
            _ = try await SetupCaptureLookup.scan(client: .codex, after: boundary,
                loadPage: { _, _ in throw GlanceClientError.http(503) },
                loadDetail: { id in loaded = true; return try self.detail(id, eventID: "evt", at: 1_001) })
            XCTFail("List failure must propagate")
        } catch GlanceClientError.http(503) {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(loaded)
    }

    func testPageBudgetPreservesNextOffsetAndRepeatedPagesStop() async throws {
        let rows = [session("other-1", client: "hermes"), session("other-2", client: "hermes")]
        var pages = 0
        let first = try await SetupCaptureLookup.scan(client: .codex, after: boundary, pageSize: 2, pageBudget: 1,
            loadPage: { _, offset in pages += 1; return try self.page(rows, offset: offset, truncated: true) },
            loadDetail: { _ in XCTFail("Foreign clients must not load"); throw GlanceClientError.http(404) })
        XCTAssertNil(first.capture)
        XCTAssertEqual(first.nextCursor.offset, 2)
        XCTAssertEqual(pages, 1)

        pages = 0
        let repeated = try await SetupCaptureLookup.scan(client: .codex, after: boundary, pageSize: 2,
            loadPage: { _, offset in pages += 1; return try self.page(rows, offset: offset, truncated: true) },
            loadDetail: { _ in throw GlanceClientError.http(404) })
        XCTAssertNil(repeated.capture)
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(repeated.nextCursor.offset, 0)
    }

    func testCursorScopeAndGenerationRejectPriorStoreBoundaryAndLateRequests() {
        let storeA = URL(fileURLWithPath: "/synthetic/store-a")
        let storeB = URL(fileURLWithPath: "/synthetic/store-b")
        var state = SetupCaptureCursorState()
        let original = state.begin(store: storeA, client: .codex, boundary: boundary)
        state.finish(original, nextCursor: .init(offset: 12))
        XCTAssertEqual(state.begin(store: storeA, client: .codex, boundary: boundary).cursor.offset, 12)
        XCTAssertEqual(state.begin(store: storeA, client: .hermes, boundary: boundary).cursor.offset, 0)

        let laterBoundary = boundary.addingTimeInterval(10)
        XCTAssertEqual(state.begin(store: storeA, client: .codex, boundary: laterBoundary).cursor.offset, 0)
        state.finish(original, nextCursor: .init(offset: 99))
        XCTAssertEqual(state.begin(store: storeA, client: .codex, boundary: laterBoundary).cursor.offset, 0)

        let prior = state.begin(store: storeB, client: .codex, boundary: laterBoundary)
        XCTAssertEqual(prior.cursor.offset, 0)
        let newer = state.begin(store: storeB, client: .codex, boundary: laterBoundary)
        state.finish(newer, nextCursor: .init(offset: 24))
        state.finish(prior, nextCursor: .init(offset: 12))
        XCTAssertEqual(state.begin(store: storeB, client: .codex, boundary: laterBoundary).cursor.offset, 24)
    }

    private func session(_ id: String, client: String = "codex", key: String? = nil) -> [String: Any] {
        ["client": client, "client_session_id": id, "session_key": key ?? "\(client)::\(id)", "last_activity_at": 1_100]
    }

    private func page(_ rows: [[String: Any]], offset: Int, truncated: Bool) throws -> V1SessionsPayload {
        try decode(["schema": "agentacct.v1-sessions.v1", "offset": offset, "truncated": truncated, "sessions": rows])
    }

    private func detail(_ id: String, client: String = "codex", key: String? = nil, eventID: String?, at time: Double) throws -> V1SessionDetail {
        var step: [String: Any] = ["section_id": "work", "updated_at": time]
        if let eventID { step["latest_event_id"] = eventID }
        return try decode(["schema": "agentacct.v1-session-detail.v1", "session": session(id, client: client, key: key), "steps": [step], "descendants": []])
    }

    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
