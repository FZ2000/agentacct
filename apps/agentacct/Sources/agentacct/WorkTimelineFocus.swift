import Foundation

/// One explicit return request survives a temporary setup/activation route.
/// It is consumed only by the returning task and never crosses a task change.
struct WorkTimelineFocusRestoration {
    enum Target: Equatable { case record(String), heading }
    struct Request: Equatable {
        let taskID: String
        let recordID: String?
    }
    private var lastTaskID: String?
    private var lastRecordID: String?
    private(set) var pending: Request?

    mutating func remember(taskID: String, recordID: String?) {
        lastTaskID = taskID
        lastRecordID = recordID
    }

    mutating func prepare(taskID: String) {
        pending = Request(taskID: taskID, recordID: lastTaskID == taskID ? lastRecordID : nil)
    }

    mutating func cancel() { pending = nil }

    mutating func consume(taskID: String, visibleRecordIDs: Set<String>) -> Target? {
        guard let request = pending else { return nil }
        pending = nil
        guard request.taskID == taskID else { return nil }
        if let id = request.recordID, visibleRecordIDs.contains(id) { return .record(id) }
        return .heading
    }
}
