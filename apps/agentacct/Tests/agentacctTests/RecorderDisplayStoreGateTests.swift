import XCTest
@testable import agentacct

final class RecorderDisplayStoreGateTests: XCTestCase {
    func testOnlyMatchingIdentifiedStoreCanReconnectManagedRuntime() {
        XCTAssertNil(RecorderDisplayStoreGate.explanation(display: URL(fileURLWithPath: "/tmp/recording"), managedPath: "/tmp/recording"))
        XCTAssertNotNil(RecorderDisplayStoreGate.explanation(display: URL(fileURLWithPath: "/tmp/other"), managedPath: "/tmp/recording"))
        XCTAssertNotNil(RecorderDisplayStoreGate.explanation(display: nil, managedPath: "/tmp/recording"))
        XCTAssertNotNil(RecorderDisplayStoreGate.explanation(display: URL(fileURLWithPath: "/tmp/recording"), managedPath: nil))
    }

    func testCanonicalAliasRefersToTheSameOwnedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store)
        XCTAssertNil(RecorderDisplayStoreGate.explanation(display: alias, managedPath: store.path))
    }
}
