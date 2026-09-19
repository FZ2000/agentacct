import Foundation
import XCTest
@testable import agentacct

final class SavedWorkSnapshotTests: XCTestCase {
    func testOnlyWorkResponsesAreSavedAndStoreIdentityIsChecked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let cache = SavedWorkCache()
        let body = Data("{\"ok\":true}".utf8)
        await cache.record(path: "/v1/receipt?task=a", data: body, store: store, cacheRoot: root)
        await cache.record(path: "/local-api.json", data: Data("secret".utf8), store: store, cacheRoot: root)
        let saved = try XCTUnwrap(SavedWorkSnapshot.load(store: store, cacheRoot: root))
        XCTAssertEqual(saved.entries.count, 1)
        XCTAssertEqual(saved.entries["/v1/receipt?task=a"]?.data, body)
        XCTAssertNil(SavedWorkSnapshot.load(store: root.appendingPathComponent("different"), cacheRoot: root))
        let attrs = try FileManager.default.attributesOfItem(atPath: SavedWorkSnapshot.location(store: store, cacheRoot: root).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var wrong = saved
        wrong.schema = 99
        try JSONEncoder().encode(wrong).write(to: SavedWorkSnapshot.location(store: store, cacheRoot: root))
        XCTAssertNil(SavedWorkSnapshot.load(store: store, cacheRoot: root))
    }

    func testUnchangedCopyKeepsItsActualOlderDateAndChangedDataIsWritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SavedWorkCache()
        let date = Date(timeIntervalSince1970: 100)
        await cache.record(path: "/v1/receipt?task=a", data: Data("old".utf8), store: root, receivedAt: date, cacheRoot: root)
        await cache.record(path: "/v1/receipt?task=a", data: Data("old".utf8), store: root, receivedAt: date.addingTimeInterval(3), cacheRoot: root)
        XCTAssertEqual(SavedWorkSnapshot.load(store: root, cacheRoot: root)?.entries.values.first?.receivedAt, date)
        await cache.record(path: "/v1/receipt?task=a", data: Data("new".utf8), store: root, receivedAt: date.addingTimeInterval(4), cacheRoot: root)
        XCTAssertEqual(SavedWorkSnapshot.load(store: root, cacheRoot: root)?.entries.values.first?.data, Data("new".utf8))
    }

    func testOlderRequestCannotOverwriteNewerAcceptedResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SavedWorkCache()
        await cache.record(path: "/v1/receipt?task=a", data: Data("new".utf8), store: root,
                           receivedAt: Date(timeIntervalSince1970: 30), requestStartedAt: Date(timeIntervalSince1970: 20), cacheRoot: root)
        await cache.record(path: "/v1/receipt?task=a", data: Data("old".utf8), store: root,
                           receivedAt: Date(timeIntervalSince1970: 40), requestStartedAt: Date(timeIntervalSince1970: 10), cacheRoot: root)
        XCTAssertEqual(SavedWorkSnapshot.load(store: root, cacheRoot: root)?.entries.values.first?.data, Data("new".utf8))
    }

    func testThrottledSameBodyStillAdvancesRequestOrdering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SavedWorkCache()
        await cache.record(path: "/v1/receipt?task=a", data: Data("A".utf8), store: root,
                           receivedAt: Date(timeIntervalSince1970: 15), requestStartedAt: Date(timeIntervalSince1970: 10), cacheRoot: root)
        await cache.record(path: "/v1/receipt?task=a", data: Data("A".utf8), store: root,
                           receivedAt: Date(timeIntervalSince1970: 35), requestStartedAt: Date(timeIntervalSince1970: 30), cacheRoot: root)
        await cache.record(path: "/v1/receipt?task=a", data: Data("B".utf8), store: root,
                           receivedAt: Date(timeIntervalSince1970: 40), requestStartedAt: Date(timeIntervalSince1970: 25), cacheRoot: root)
        XCTAssertEqual(SavedWorkSnapshot.load(store: root, cacheRoot: root)?.entries.values.first?.data, Data("A".utf8))
        XCTAssertEqual(SavedWorkSnapshot.load(store: root, cacheRoot: root)?.entries.values.first?.receivedAt, Date(timeIntervalSince1970: 15))
    }

    func testOfflineClientReadsOnlySavedResponsesAndRejectsWrites() async throws {
        let path = "/v1/receipt?task=a"
        let saved = SavedWorkSnapshot(storePath: "/does-not-exist", entries: [path: .init(path: path, receivedAt: Date(), data: Data("{\"ok\":true}".utf8))])
        let client = GlanceClient(savedWork: saved)
        let result: [String: Bool] = try await client.getAuthed(path)
        XCTAssertEqual(result, ["ok": true])
        do {
            let _: [String: Bool] = try await client.getAuthed("/v1/receipt?task=missing")
            XCTFail("Missing copies must not fall through to the recorder")
        } catch SavedWorkError.notSaved {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            let _: [String: Bool] = try await client.postAuthed("/v1/disposition", body: [:])
            XCTFail("An offline copy must never accept a write")
        } catch SavedWorkError.readOnly {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor func testSessionCopyDateUsesExactEncodedIdentityAndMissingCopyStaysUnknown() {
        let path = "/v1/session?client=codex&session_id=session%3Aa%26b"
        let date = Date(timeIntervalSince1970: 123)
        let saved = SavedWorkSnapshot(storePath: "/synthetic", entries: [
            path: .init(path: path, receivedAt: date, data: Data())
        ])
        let dashboard = DashboardStore(savedWork: saved)
        XCTAssertEqual(dashboard.sessionSavedAt(client: "codex", sessionID: "session:a&b"), date)
        XCTAssertNil(dashboard.sessionSavedAt(client: "claude-code", sessionID: "session:a&b"))
        XCTAssertNil(dashboard.sessionSavedAt(client: "codex", sessionID: "missing"))
    }

    @MainActor func testQueryValuesCannotBecomeAdditionalParameters() {
        XCTAssertEqual(DashboardStore.queryValue("session:a&client=other/#"), "session%3Aa%26client%3Dother%2F%23")
    }
}
