import XCTest
@testable import agentacct

/// Session index rows show one recognizable label per session; the opaque
/// identity's distinguishing tail is the fallback when no title exists.
final class SessionIndexTests: XCTestCase {
    func testDistinguishingIDKeepsOnlyTheShorterTail() {
        XCTAssertEqual(sessionDistinguishingID("codex:2026-09-12:abc123"), "abc123")
        XCTAssertEqual(sessionDistinguishingID("plain-id"), "plain-id")
        XCTAssertEqual(sessionDistinguishingID("a:b"), "b")
    }
}
