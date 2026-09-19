import Foundation

struct SetupCaptureScanCursor: Equatable {
    var offset = 0
}

/// A pending client's bounded scan resumes after the last examined list row.
/// Scope and request generation prevent a different store, activation attempt,
/// or late concurrent response from reusing or rewinding that cursor.
struct SetupCaptureCursorState {
    struct Key: Hashable {
        let storePath: String
        let clientID: String
        let boundary: Date
    }
    struct Ticket {
        let key: Key
        let cursor: SetupCaptureScanCursor
        let generation: Int
    }
    private struct Entry {
        let cursor: SetupCaptureScanCursor
        let generation: Int
    }
    private var entries: [Key: Entry] = [:]
    private var generation = 0

    mutating func begin(store: URL, client: SetupClient, boundary: Date) -> Ticket {
        let path = store.standardizedFileURL.resolvingSymlinksInPath().path
        entries = entries.filter { key, _ in
            key.storePath == path && (key.clientID != client.rawValue || key.boundary == boundary)
        }
        let key = Key(storePath: path, clientID: client.rawValue, boundary: boundary)
        let cursor = entries[key]?.cursor ?? SetupCaptureScanCursor()
        generation &+= 1
        entries[key] = Entry(cursor: cursor, generation: generation)
        return Ticket(key: key, cursor: cursor, generation: generation)
    }

    mutating func finish(_ ticket: Ticket, nextCursor: SetupCaptureScanCursor) {
        guard entries[ticket.key]?.generation == ticket.generation else { return }
        entries[ticket.key] = Entry(cursor: nextCursor, generation: ticket.generation)
    }
}

enum SetupCaptureLookupError: Error {
    case incompatibleSessionList
    case paginationChanged
    case storeChanged
}

@MainActor
enum SetupCaptureLookup {
    struct Result {
        let capture: SetupCaptureConfirmation?
        let nextCursor: SetupCaptureScanCursor
    }

    /// Recency narrows candidates only. Each confirmed result still comes from
    /// an exact client's session and a named event strictly after the boundary.
    /// Nil means no proof in this bounded scan, never complete absence.
    static func scan(
        client: SetupClient,
        after boundary: Date,
        cursor: SetupCaptureScanCursor = .init(),
        pageSize: Int = 50,
        pageBudget: Int = 3,
        detailBudget: Int = 12,
        loadPage: (_ limit: Int, _ offset: Int) async throws -> V1SessionsPayload,
        loadDetail: (_ sessionID: String) async throws -> V1SessionDetail
    ) async throws -> Result {
        guard pageSize > 0, pageBudget > 0, detailBudget > 0 else {
            return Result(capture: nil, nextCursor: cursor)
        }
        var offset = max(0, cursor.offset)
        var seen: Set<String> = []
        var detailsRequested = 0
        for _ in 0..<pageBudget {
            try Task.checkCancellation()
            let pageOffset = offset
            let page = try await loadPage(pageSize, pageOffset)
            try Task.checkCancellation()
            guard page.schema == "agentacct.v1-sessions.v1" else { throw SetupCaptureLookupError.incompatibleSessionList }
            guard (page.offset == nil || page.offset == pageOffset), page.sessions.count <= pageSize else {
                throw SetupCaptureLookupError.paginationChanged
            }
            guard !page.sessions.isEmpty else {
                return Result(capture: nil, nextCursor: .init())
            }
            let hasAnotherPage = page.truncated ?? (page.sessions.count >= pageSize)
            var newRows = false
            for (index, row) in page.sessions.enumerated() {
                try Task.checkCancellation()
                offset = pageOffset + index + 1
                guard seen.insert(row.id).inserted else { continue }
                newRows = true
                // Older daemons ignore unknown client query parameters. Keep
                // exact local filtering even with server-side client scope.
                guard row.client == client.rawValue,
                      WorkTimelineProjection.nonempty(row.clientSessionId) != nil else { continue }
                let key = "\(client.rawValue)::\(row.clientSessionId)"
                guard row.sessionKey == nil || row.sessionKey == key else { continue }
                if let time = WorkTimelineProjection.validTime(row.lastActivityAt), time <= boundary.timeIntervalSince1970 {
                    continue
                }
                detailsRequested += 1
                do {
                    let detail = try await loadDetail(row.clientSessionId)
                    try Task.checkCancellation()
                    if detail.schema == "agentacct.v1-session-detail.v1",
                       detail.session.client == client.rawValue,
                       detail.session.clientSessionId == row.clientSessionId,
                       detail.session.id == key,
                       let capture = SetupCaptureObserver.confirmation(in: detail, client: client, after: boundary) {
                        return Result(capture: capture, nextCursor: .init())
                    }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    if let lookupError = error as? SetupCaptureLookupError, case .storeChanged = lookupError { throw error }
                    try Task.checkCancellation()
                    // A missing, unreadable, or individually failing detail
                    // cannot prevent a later candidate from supplying proof.
                }
                if detailsRequested >= detailBudget {
                    let finished = index == page.sessions.count - 1 && !hasAnotherPage
                    return Result(capture: nil, nextCursor: .init(offset: finished ? 0 : offset))
                }
            }
            if !newRows || !hasAnotherPage {
                return Result(capture: nil, nextCursor: .init())
            }
        }
        return Result(capture: nil, nextCursor: .init(offset: offset))
    }
}
