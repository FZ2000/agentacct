import Foundation

/// Selects a recovery page, never performs recovery. Every connection route
/// still passes through SetupModel's installed-recorder and store safeguards.
enum RecordingSetupRoute: Equatable {
    case configuration
    case connection(reason: String)
    case synchronization(reason: String)

    @MainActor
    static func project(
        selectedCause: RecordingHealthCause? = nil,
        currentCauses: [RecordingHealthCause],
        setupPhase: SetupModel.Phase,
        synchronizationFinished: Bool
    ) -> RecordingSetupRoute {
        if !synchronizationFinished, case .failed(let message) = setupPhase {
            return .synchronization(reason: message)
        }
        guard synchronizationFinished else { return .configuration }

        if let selectedCause {
            return connectionReason(for: selectedCause).map { .connection(reason: $0) } ?? .configuration
        }
        // Generic Connections prefers the current endpoint failure, then a
        // watcher failure. Explicit selection preserves the chosen explanation.
        let candidate = currentCauses.first { $0.scope == .endpoint && connectionReason(for: $0) != nil }
            ?? currentCauses.first { connectionReason(for: $0) != nil }
        return candidate.flatMap(connectionReason).map { .connection(reason: $0) } ?? .configuration
    }

    private static func connectionReason(for cause: RecordingHealthCause) -> String? {
        guard cause.action == .setup else { return nil }
        let endpoint = cause.scope == .endpoint && ["endpoint:unreachable", "endpoint:incompatible"].contains(cause.id)
        let watcher = cause.scope == .ingestion && cause.id == "ingestion:watcher"
        return endpoint || watcher ? cause.detail : nil
    }
}
