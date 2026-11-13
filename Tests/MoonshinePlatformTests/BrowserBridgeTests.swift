import XCTest
import MoonshineCore
@testable import MoonshinePlatform

final class BrowserBridgeTests: XCTestCase {
    private let client = UUID().uuidString, session = UUID().uuidString
    private func message(version: Int = 1, session: String? = nil, acks: [[String: Any]] = [], tabs: [[String: Any]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "client": client, "session": session ?? self.session, "browser": "Safari", "transportVersion": version,
            "tabs": tabs ?? [["id": 17, "windowId": 4, "title": "Synthetic tab", "url": "https://example.org", "incognito": false]],
            "acknowledgements": acks
        ])
    }
    private func commands(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)
        return (object as? [[String: Any]]) ?? (object as? [String: Any])?["commands"] as? [[String: Any]] ?? []
    }

    func testWaitingSyncWakesForExactCommandAndAckCompletesBeforeNextPoll() async throws {
        let bridge = BrowserBridge(token: "synthetic")
        _ = await bridge.sync(try message())
        let poll = Task { await bridge.sync(try message(version: 2)) }
        try await Task.sleep(for: .milliseconds(30))
        let timer = LatencyTimer()
        let target = ActivationTarget.browserBridge(client: client, session: session, tabID: 17)
        let activation = Task { try await bridge.activate(target) }
        let result = try commands(await poll.value)
        XCTAssertLessThan(timer.milliseconds, 500, "Should wake on activation, not the one-second heartbeat")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["tabID"] as? Int, 17)
        XCTAssertEqual(result.first?["session"] as? String, session)
        let id = try XCTUnwrap(result.first?["id"] as? String)
        // Ack ingestion must resume activation even while this new sync is waiting.
        let ack = Task { await bridge.sync(try message(version: 2, acks: [["id": id, "success": true]])) }
        try await activation.value
        XCTAssertLessThan(timer.milliseconds, 500)
        _ = try await ack.value
    }

    func testLegacyResponseAndPrivateExclusion() async throws {
        let bridge = BrowserBridge(token: "synthetic")
        let response = await bridge.sync(try message(tabs: [["id": 17, "windowId": 4, "title": "Private", "incognito": true]]))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: response) as? [Any])
        let inventory = await bridge.inventory()
        XCTAssertTrue(inventory.isEmpty)
        do {
            try await bridge.activate(.browserBridge(client: client, session: session, tabID: 17))
            XCTFail("Private ID must be unavailable")
        } catch { XCTAssertTrue(error is NavigationError) }
    }

    func testRestartedSessionInvalidatesPendingActivation() async throws {
        let bridge = BrowserBridge(token: "synthetic")
        _ = await bridge.sync(try message())
        let activation = Task { try await bridge.activate(.browserBridge(client: client, session: session, tabID: 17)) }
        try await Task.sleep(for: .milliseconds(30))
        let old = try commands(await bridge.sync(try message()))
        XCTAssertEqual(old.count, 1)
        let newSession = UUID().uuidString
        let response = await bridge.sync(try message(session: newSession, acks: [["id": old[0]["id"]!, "success": true]]))
        XCTAssertTrue(try commands(response).isEmpty)
        do { try await activation.value; XCTFail("Old-session acknowledgement must not succeed") }
        catch { XCTAssertTrue(error is NavigationError) }
    }

    func testInventoryStreamPublishesChangedTabsWithoutNativeRefresh() async throws {
        let bridge = BrowserBridge(token: "synthetic")
        var stream = await bridge.inventoryUpdates().makeAsyncIterator()
        _ = await stream.next() // initial snapshot
        _ = await bridge.sync(try message())
        _ = await stream.next()
        let added = await bridge.inventory()
        XCTAssertEqual(added.count, 1)
        _ = await bridge.sync(try message(tabs: []))
        _ = await stream.next()
        let removed = await bridge.inventory()
        XCTAssertTrue(removed.isEmpty)
    }
}
