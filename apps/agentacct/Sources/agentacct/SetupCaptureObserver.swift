import Foundation

/// Capture comes from a named event inside the selected client's session.
/// Session recency only narrows the search; it never confirms capture itself.
enum SetupCaptureObserver {
    static func confirmation(
        in detail: V1SessionDetail,
        client: SetupClient,
        after boundary: Date,
        taskID: String? = nil
    ) -> SetupCaptureConfirmation? {
        guard detail.session.client == client.rawValue else { return nil }
        var candidates: [(String, Double)] = []
        for step in detail.steps {
            if let id = WorkTimelineProjection.nonempty(step.latestEventId),
               let time = WorkTimelineProjection.validTime(step.updatedAt) {
                candidates.append((id, time))
            }
            for check in step.checks ?? [] {
                if let id = WorkTimelineProjection.nonempty(check.eventId),
                   let time = WorkTimelineProjection.validTime(check.createdAt) {
                    candidates.append((id, time))
                }
            }
        }
        guard let event = candidates.filter({ $0.1 > boundary.timeIntervalSince1970 })
            .max(by: { $0.1 < $1.1 }) else { return nil }
        return SetupCaptureConfirmation(clientID: client.rawValue, eventID: event.0,
            observedAt: Date(timeIntervalSince1970: event.1), taskID: taskID,
            clientSessionID: detail.session.clientSessionId,
            sessionKey: detail.session.id)
    }
}

struct SetupCaptureTaskAssociation: Equatable, Hashable {
    let taskID: String
    let sessionKey: String
}

/// Task linkage is enrichment of existing capture evidence. It never supplies
/// capture itself, and never matches titles, projects, prefixes, or recency.
enum SetupCaptureTaskResolver {
    static func associations(
        tasks: [ReceiptSummary],
        receipts: [Receipt]
    ) -> [SetupCaptureTaskAssociation] {
        var result: Set<SetupCaptureTaskAssociation> = []
        for task in tasks {
            if let root = task.primaryRoot, !task.taskId.isEmpty {
                result.insert(.init(taskID: task.taskId, sessionKey: root.sessionKey))
            }
        }
        for receipt in receipts where !receipt.taskId.isEmpty {
            for group in receipt.sessions ?? [] {
                result.insert(.init(taskID: receipt.taskId, sessionKey: group.root.sessionKey))
                for member in group.members {
                    result.insert(.init(taskID: receipt.taskId, sessionKey: member.ref.sessionKey))
                }
            }
        }
        return result.sorted {
            $0.taskID == $1.taskID ? $0.sessionKey < $1.sessionKey : $0.taskID < $1.taskID
        }
    }

    static func taskID(
        for capture: SetupCaptureConfirmation,
        associations: [SetupCaptureTaskAssociation]
    ) -> String? {
        guard let sessionKey = capture.exactSessionKey else { return nil }
        let matches = Set(associations.filter { $0.sessionKey == sessionKey }.map(\.taskID))
        return matches.count == 1 ? matches.first : nil
    }
}
