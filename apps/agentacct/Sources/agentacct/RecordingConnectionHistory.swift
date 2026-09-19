import CryptoKit
import Foundation

/// What this app observed after each successful configuration command. This is
/// history, not a claim that client configuration remains intact indefinitely.
struct RecordingConnectionHistory: Codable, Equatable {
    var boundaries: [String: Date] = [:]
    var captures: [String: SetupCaptureConfirmation] = [:]
    var setupLogs: [String: [String]] = [:]
    /// Capture and task identities belong to this canonical recording store.
    /// An unbound decoded history is readable for audit, but cannot be saved or
    /// accepted by `load` as proof for the currently displayed store.
    private(set) var storePath: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case boundaries, captures, setupLogs, storePath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        boundaries = try values.decode([String: Date].self, forKey: .boundaries)
        captures = try values.decode([String: SetupCaptureConfirmation].self, forKey: .captures)
        setupLogs = try values.decodeIfPresent([String: [String]].self, forKey: .setupLogs) ?? [:]
        storePath = try values.decodeIfPresent(String.self, forKey: .storePath)
    }

    var pending: [String: Date] {
        boundaries.filter { id, boundary in
            guard let client = SetupClient(rawValue: id) else { return false }
            return captures[id]?.confirms(client: client, after: boundary) != true
        }
    }
    var pendingKey: String {
        pending.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.timeIntervalSince1970)" }.joined(separator: "|")
    }

    mutating func configured(_ client: SetupClient, at boundary: Date, setupLog: [String]? = nil) {
        boundaries[client.rawValue] = boundary
        // Reconnect advances the capture boundary without running onboarding;
        // keep its previous setup output unless new output was supplied.
        if let setupLog { setupLogs[client.rawValue] = setupLog }
    }

    mutating func observed(_ capture: SetupCaptureConfirmation) {
        guard let client = SetupClient(rawValue: capture.clientID),
              capture.confirms(client: client, after: boundaries[capture.clientID]) else { return }
        captures[capture.clientID] = capture
    }

    /// A delayed tasks response may supply the link after capture was already
    /// confirmed. Filling that link must not change the event, its observation
    /// date, session identity, or the client's pending/confirmed state.
    @discardableResult
    mutating func enrichTaskAssociations(
        using resolve: (SetupCaptureConfirmation) -> String?
    ) -> Bool {
        var changed = false
        for (clientID, capture) in captures where capture.taskID == nil {
            guard capture.exactSessionKey != nil,
                  let taskID = resolve(capture), !taskID.isEmpty else { continue }
            captures[clientID] = capture.associatingTask(taskID)
            changed = true
        }
        return changed
    }

    static let legacyPreferencesKey = "agentacct.recording.connection-history.v1"

    static func canonicalStorePath(_ store: URL) -> String {
        store.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func preferencesKey(store: URL) -> String {
        preferencesKey(canonicalStorePath: canonicalStorePath(store))
    }

    private static func preferencesKey(canonicalStorePath: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalStorePath.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "agentacct.recording.connection-history.v2.\(digest)"
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard !SnapshotMode.enabled else { return Self() }
        return load(store: try? GlanceClient.storeDir(), defaults: defaults)
    }

    static func load(store: URL?, defaults: UserDefaults = .standard) -> Self {
        guard !SnapshotMode.enabled, let store, store.isFileURL else { return Self() }
        let path = canonicalStorePath(store)
        var empty = Self()
        empty.storePath = path
        // Do not migrate the old unbound key: it cannot identify which store
        // supplied its confirmations. Leave its bytes untouched for audit.
        guard let data = defaults.data(forKey: preferencesKey(canonicalStorePath: path)),
              let history = try? JSONDecoder().decode(Self.self, from: data),
              history.storePath == path else { return empty }
        return history
    }

    func save(defaults: UserDefaults = .standard) {
        guard !SnapshotMode.enabled, let storePath,
              let data = try? JSONEncoder().encode(self) else { return }
        // Save to the store bound at load time. A later display-store change
        // must never relabel this history's existing capture evidence.
        defaults.set(data, forKey: Self.preferencesKey(canonicalStorePath: storePath))
    }
}
