import XCTest
@testable import agentacct

final class RecordingConnectionHistoryTests: XCTestCase {
    func testSecondClientRetainsFirstClientsPendingBoundaryAndConfirmation() throws {
        var history = RecordingConnectionHistory()
        let first = Date(timeIntervalSince1970: 1_000)
        history.configured(.codex, at: first)
        history.configured(.claudeCode, at: first.addingTimeInterval(20))
        history.observed(.init(clientID: "claude-code", eventID: "evt-claude", observedAt: first.addingTimeInterval(21), taskID: nil))
        XCTAssertEqual(Set(history.pending.keys), ["codex"])
        history.observed(.init(clientID: "codex", eventID: "evt-codex", observedAt: first.addingTimeInterval(30), taskID: nil))
        XCTAssertTrue(history.pending.isEmpty)
        XCTAssertEqual(history.captures.count, 2)
        let decoded = try JSONDecoder().decode(RecordingConnectionHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    func testReconfigurationNeedsFreshEvidenceWithoutErasingOtherClient() {
        var history = RecordingConnectionHistory()
        let first = Date(timeIntervalSince1970: 1_000)
        history.configured(.codex, at: first)
        history.observed(.init(clientID: "codex", eventID: "evt-old", observedAt: first.addingTimeInterval(1), taskID: nil))
        history.configured(.codex, at: first.addingTimeInterval(10))
        XCTAssertEqual(Set(history.pending.keys), ["codex"])
        history.observed(.init(clientID: "hermes", eventID: "evt-other", observedAt: first.addingTimeInterval(20), taskID: nil))
        XCTAssertNil(history.captures["hermes"])
        XCTAssertEqual(history.captures["codex"]?.eventID, "evt-old")
    }

    func testStoreHistoriesRemainSeparateAcrossReloads() throws {
        let defaults = isolatedDefaults()
        let firstStore = URL(fileURLWithPath: "/tmp/agentacct-history-store-a")
        let secondStore = URL(fileURLWithPath: "/tmp/agentacct-history-store-b")
        let boundary = Date(timeIntervalSince1970: 1_000)
        var first = RecordingConnectionHistory.load(store: firstStore, defaults: defaults)
        first.configured(.codex, at: boundary, setupLog: ["Codex output"])
        first.observed(.init(clientID: "codex", eventID: "evt-a", observedAt: boundary.addingTimeInterval(1), taskID: "task-a"))
        first.save(defaults: defaults)

        var second = RecordingConnectionHistory.load(store: secondStore, defaults: defaults)
        XCTAssertTrue(second.boundaries.isEmpty)
        XCTAssertTrue(second.captures.isEmpty)
        XCTAssertTrue(second.setupLogs.isEmpty)
        second.configured(.hermes, at: boundary, setupLog: ["Hermes consent"])
        second.save(defaults: defaults)

        XCTAssertEqual(RecordingConnectionHistory.load(store: firstStore, defaults: defaults), first)
        XCTAssertEqual(RecordingConnectionHistory.load(store: secondStore, defaults: defaults), second)
        // Saving the original value stays bound to A after B was loaded.
        first.configured(.claudeCode, at: boundary.addingTimeInterval(5))
        first.save(defaults: defaults)
        XCTAssertEqual(RecordingConnectionHistory.load(store: secondStore, defaults: defaults), second)
        XCTAssertNil(second.captures["codex"])
    }

    func testCanonicalAliasesShareOnlyTheirResolvedStoreHistory() throws {
        let defaults = isolatedDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store)
        var history = RecordingConnectionHistory.load(store: alias, defaults: defaults)
        history.configured(.codex, at: Date(timeIntervalSince1970: 1_000))
        history.save(defaults: defaults)

        XCTAssertEqual(RecordingConnectionHistory.preferencesKey(store: alias), RecordingConnectionHistory.preferencesKey(store: store))
        XCTAssertEqual(RecordingConnectionHistory.load(store: store, defaults: defaults), history)
        XCTAssertEqual(history.storePath, RecordingConnectionHistory.canonicalStorePath(store))
    }

    func testLegacyUnboundHistoryIsPreservedButNeverLoadedAsCurrentProof() throws {
        let defaults = isolatedDefaults()
        let store = URL(fileURLWithPath: "/tmp/agentacct-history-legacy")
        let json = """
        {"boundaries":{"codex":1000},"captures":{"codex":{"clientID":"codex","eventID":"evt-old","observedAt":1001,"taskID":"task-old"}}}
        """
        let legacy = Data(json.utf8)
        defaults.set(legacy, forKey: RecordingConnectionHistory.legacyPreferencesKey)

        var current = RecordingConnectionHistory.load(store: store, defaults: defaults)
        XCTAssertTrue(current.boundaries.isEmpty)
        XCTAssertTrue(current.captures.isEmpty)
        XCTAssertTrue(current.setupLogs.isEmpty)
        current.configured(.hermes, at: Date(timeIntervalSince1970: 2_000))
        current.save(defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: RecordingConnectionHistory.legacyPreferencesKey), legacy)
        XCTAssertEqual(RecordingConnectionHistory.load(store: store, defaults: defaults), current)
    }

    func testStoreKeyRejectsPayloadFromAnotherStoreWithoutRewritingIt() throws {
        let defaults = isolatedDefaults()
        let firstStore = URL(fileURLWithPath: "/tmp/agentacct-history-original")
        let secondStore = URL(fileURLWithPath: "/tmp/agentacct-history-wrong-copy")
        var first = RecordingConnectionHistory.load(store: firstStore, defaults: defaults)
        first.configured(.codex, at: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(first)
        let wrongKey = RecordingConnectionHistory.preferencesKey(store: secondStore)
        defaults.set(data, forKey: wrongKey)

        let loaded = RecordingConnectionHistory.load(store: secondStore, defaults: defaults)

        XCTAssertEqual(loaded.storePath, RecordingConnectionHistory.canonicalStorePath(secondStore))
        XCTAssertTrue(loaded.boundaries.isEmpty)
        XCTAssertTrue(loaded.captures.isEmpty)
        XCTAssertEqual(defaults.data(forKey: wrongKey), data)
    }

    func testUnresolvedOrUnboundHistoryDoesNotWritePreferences() throws {
        let defaults = isolatedDefaults()
        let originalKeys = Set(defaults.dictionaryRepresentation().keys)
        var unresolved = RecordingConnectionHistory.load(store: nil, defaults: defaults)
        unresolved.configured(.codex, at: Date(timeIntervalSince1970: 1_000))
        unresolved.save(defaults: defaults)
        var unbound = RecordingConnectionHistory()
        unbound.configured(.hermes, at: Date(timeIntervalSince1970: 1_000))
        unbound.save(defaults: defaults)

        XCTAssertNil(unresolved.storePath)
        XCTAssertNil(unbound.storePath)
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys), originalKeys)
    }

    func testPerClientSetupOutputSurvivesReconnectBoundaryAndReload() throws {
        let defaults = isolatedDefaults()
        let store = URL(fileURLWithPath: "/tmp/agentacct-history-output")
        let boundary = Date(timeIntervalSince1970: 1_000)
        var history = RecordingConnectionHistory.load(store: store, defaults: defaults)
        history.configured(.codex, at: boundary, setupLog: ["Codex approval"])
        history.configured(.hermes, at: boundary, setupLog: ["Hermes consent"])
        history.configured(.codex, at: boundary.addingTimeInterval(10))
        history.save(defaults: defaults)

        var reloaded = RecordingConnectionHistory.load(store: store, defaults: defaults)
        XCTAssertEqual(reloaded.setupLogs["codex"], ["Codex approval"])
        XCTAssertEqual(reloaded.setupLogs["hermes"], ["Hermes consent"])
        XCTAssertEqual(reloaded.pending["codex"], boundary.addingTimeInterval(10))
        reloaded.configured(.codex, at: boundary.addingTimeInterval(20), setupLog: ["New Codex setup"])
        XCTAssertEqual(reloaded.setupLogs["codex"], ["New Codex setup"])
        XCTAssertEqual(reloaded.setupLogs["hermes"], ["Hermes consent"])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "agentacct-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
