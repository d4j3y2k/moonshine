import XCTest
@testable import MoonshineCore

actor FakeTransport: DecisionTransport {
    var calls = 0
    var data: Data
    init(_ data: String) { self.data = Data(data.utf8) }
    func send(body: Data) async throws -> Data { calls += 1; return data }
}

final class DecisionTests: XCTestCase {
    let item = WorkspaceItem(id: "private-local-id", kind: .window, app: "Editor", title: "Nocturne")
    func batch() -> DecisionBatch { DecisionBatch(query: "music", evidence: [item.evidence]) }
    func testResponseRequiresKnownUniqueAliasesAndCompleteSet() throws {
        for json in [
            "{\"answers\":[{\"name\":\"invented\",\"type\":\"predicate\",\"probability\":1}]}",
            "{\"answers\":[]}",
            "{\"answers\":[{\"name\":\"c0\",\"type\":\"predicate\",\"probability\":2}]}",
            "{\"answers\":[{\"name\":\"c0\",\"type\":\"choice\",\"probability\":1}]}"
        ] { XCTAssertThrowsError(try batch().decode(Data(json.utf8))) }
        let repeated = DecisionBatch(query: "music", evidence: [item.evidence, WorkspaceItem(id: "b", kind: .window, app: "X", title: "X").evidence])
        XCTAssertThrowsError(try repeated.decode(Data("{\"answers\":[{\"name\":\"c0\",\"type\":\"refusal\"},{\"name\":\"c0\",\"type\":\"refusal\"}]}".utf8)))
    }
    func testRefusalsPreserveLocalFallback() throws {
        XCTAssertEqual(try batch().decode(Data("{\"answers\":[{\"name\":\"c0\",\"type\":\"refusal\"}]}".utf8)), [:])
    }
    func testIDsAndActivationTargetsAreNeverTransmitted() throws {
        let body = String(decoding: try batch().body(), as: UTF8.self)
        XCTAssertFalse(body.contains("private-local-id")); XCTAssertFalse(body.contains("target" + "\":"))
        XCTAssertTrue(body.contains("gpt-6-luna")); XCTAssertTrue(body.contains("predicate"))
    }
    func testCacheKeysIncludeQueryEvidenceIdentityAndPrompt() throws {
        let first = try batch().cacheKey()
        XCTAssertNotEqual(first, try DecisionBatch(query: "docs", evidence: [item.evidence]).cacheKey())
        var renamed = item; renamed.title = "New contents"
        XCTAssertNotEqual(first, try DecisionBatch(query: "music", evidence: [renamed.evidence]).cacheKey())
        var recreated = item; recreated.id = "new-id"
        XCTAssertNotEqual(first, try DecisionBatch(query: "music", evidence: [recreated.evidence]).cacheKey())
    }
    func testValidatedResponseIsCached() async throws {
        let fake = FakeTransport("{\"answers\":[{\"name\":\"c0\",\"type\":\"predicate\",\"probability\":0.8}]}")
        let engine = SemanticEngine(transport: fake)
        let first = try await engine.evaluate(batch()), second = try await engine.evaluate(batch())
        XCTAssertEqual(first, second); let calls = await fake.calls; XCTAssertEqual(calls, 1)
    }
    func testInvalidResponseIsNotCached() async throws {
        let fake = FakeTransport("{\"answers\":[]}"); let engine = SemanticEngine(transport: fake)
        for _ in 0..<2 { do { _ = try await engine.evaluate(batch()); XCTFail("Must reject") } catch {} }
        let calls = await fake.calls; XCTAssertEqual(calls, 2)
    }
    func testCacheOnlyLookupDoesNotSendAndRequiresExactEvidence() async throws {
        let fake = FakeTransport("{\"answers\":[{\"name\":\"c0\",\"type\":\"predicate\",\"probability\":0.8}]}")
        let engine = SemanticEngine(transport: fake)
        let miss = try await engine.cached([batch()])
        XCTAssertNil(miss)
        let callsBefore = await fake.calls
        XCTAssertEqual(callsBefore, 0)
        _ = try await engine.evaluate(batch())
        let hit = try await engine.cached([batch()])
        XCTAssertEqual(hit?.first?[item.id], 0.8)
        var changed = item; changed.url = "https://example.org/new-page"
        let stale = try await engine.cached([batch(), DecisionBatch(query: "music", evidence: [changed.evidence])])
        XCTAssertNil(stale, "Partial cache must not bypass debounce for new remote work")
        let callsAfter = await fake.calls
        XCTAssertEqual(callsAfter, 1)
    }
    func testCancellationPreventsWork() async throws {
        let fake = FakeTransport("{\"answers\":[]}"); let engine = SemanticEngine(transport: fake)
        let task = Task { try await Task.sleep(for: .milliseconds(40)); return try await engine.evaluate(batch()) }
        task.cancel(); do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
}
