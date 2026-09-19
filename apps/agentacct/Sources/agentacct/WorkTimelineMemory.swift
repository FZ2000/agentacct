import Foundation

/// A bounded convenience cache for revisiting tasks. Recorded evidence remains
/// in the recorder/saved-response store; eviction only discards this UI copy.
struct WorkTimelineMemoryCache {
    struct Entry {
        var feed: WorkTimelineFeed
        var recordCost: Int {
            max(1, feed.visible.records.count + feed.latest.records.count
                + (feed.historySnapshot?.records.count ?? 0))
        }
    }
    let taskLimit: Int
    let recordLimit: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    init(taskLimit: Int = 8, recordLimit: Int = 12_000) {
        self.taskLimit = max(taskLimit, 1)
        self.recordLimit = max(recordLimit, 1)
    }

    mutating func load(_ taskID: String) -> Entry? {
        guard let entry = entries[taskID] else { return nil }
        recency.removeAll { $0 == taskID }
        recency.append(taskID)
        return entry
    }

    mutating func save(_ entry: Entry, for taskID: String) {
        entries.removeValue(forKey: taskID)
        recency.removeAll { $0 == taskID }
        guard entry.recordCost <= recordLimit else { return }
        entries[taskID] = entry
        recency.append(taskID)
        while entries.count > taskLimit || entries.values.reduce(0, { $0 + $1.recordCost }) > recordLimit {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

@MainActor
enum WorkTimelineMemory {
    static var cache = WorkTimelineMemoryCache()
}
