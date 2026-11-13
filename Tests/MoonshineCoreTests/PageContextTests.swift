import XCTest
@testable import MoonshineCore

final class PageContextTests: XCTestCase {
    func item() -> WorkspaceItem {
        let url = "https://example.org/keypad?private-query#fragment"
        return WorkspaceItem(id: "keypad", kind: .browserTab, app: "Chrome", title: "Keypad", url: url,
            pageContext: PageContext(sourceURL: url, summary: "An interactive piano for composing chords", headings: ["Keyboard"], controls: ["Play", "Record"]))
    }
    func testContextRequiresOptInForLocalAndRemoteMatching() throws {
        let item = item()
        XCTAssertNil(item.evidence.page)
        XCTAssertEqual(LocalMatch.score(query: "piano", item: item), 0)
        var state = SearchState(); state.update([item]); state.setQuery("piano")
        XCTAssertTrue(state.plausibleItems.isEmpty)
        state.setUsePageContext(true)
        XCTAssertEqual(state.plausibleItems.map(\.id), [item.id])
        let body = String(decoding: try DecisionBatch(query: "piano", evidence: state.ticket.evidence).body(), as: UTF8.self)
        XCTAssertTrue(body.contains("interactive piano"))
        XCTAssertFalse(body.contains("private-query")); XCTAssertFalse(body.contains("capturedAt")); XCTAssertFalse(body.contains("sourceURL"))
        let ticket = state.ticket
        state.setUsePageContext(false)
        XCTAssertNil(state.ticket.evidence.first?.page)
        XCTAssertTrue(state.plausibleItems.isEmpty)
        XCTAssertFalse(state.apply([item.id: 1], ticket: ticket))
    }
    func testNavigationAndExpiredContextCannotRetainOldJudgments() {
        var item = item(), state = SearchState(); state.setUsePageContext(true); state.update([item]); state.setQuery("an instrument")
        let ticket = state.ticket; state.apply([item.id: 1], ticket: ticket)
        item.url = "https://example.org/unrelated"
        XCTAssertTrue(state.update([item])); XCTAssertNil(state.ticket.evidence.first?.page)
        XCTAssertFalse(state.apply([item.id: 1], ticket: ticket)); XCTAssertTrue(state.semantic.isEmpty)
        item = self.item(); state.update([item]); state.apply([item.id: 1], ticket: state.ticket)
        item.pageContext?.capturedAt -= 180
        XCTAssertTrue(state.update([item])); XCTAssertTrue(state.semantic.isEmpty)
        XCTAssertNil(state.ticket.evidence.first?.page)
    }
    func testChangedLabelsInvalidateEvidenceButCaptureTimeDoesNot() throws {
        var item = item(), state = SearchState(); state.setUsePageContext(true); state.update([item]); state.setQuery("piano")
        let first = state.ticket
        let key = try DecisionBatch(query: first.query, evidence: first.evidence).cacheKey()
        item.pageContext?.capturedAt += 1
        XCTAssertFalse(state.update([item])); XCTAssertEqual(state.ticket, first)
        XCTAssertEqual(key, try DecisionBatch(query: first.query, evidence: state.ticket.evidence).cacheKey())
        item.pageContext?.summary = "A numeric entry pad"
        XCTAssertTrue(state.update([item])); XCTAssertFalse(state.apply([item.id: 1], ticket: first))
        XCTAssertNotEqual(key, try DecisionBatch(query: first.query, evidence: state.ticket.evidence).cacheKey())
    }
    func testContextBoundsAndSourceValidation() {
        var page = item().pageContext!
        page.summary = String(repeating: "x", count: 5000)
        page.headings = (0..<50).map { String($0) + String(repeating: "h", count: 200) }
        page.controls = ["Play", "Play", "  "]
        let bounded = page.validated(for: page.sourceURL)!
        XCTAssertEqual(bounded.summary.count, 400); XCTAssertEqual(bounded.headings.count, 6)
        XCTAssertTrue(bounded.headings.allSatisfy { $0.count <= 80 }); XCTAssertEqual(bounded.controls, ["Play"])
        XCTAssertNil(page.validated(for: "https://elsewhere.org"))
        page.capturedAt = .infinity; XCTAssertNil(page.validated(for: page.sourceURL))
        for url in ["file:///private.txt", "https://user:password@example.org/"] {
            XCTAssertNil(PageContext(sourceURL: url, summary: "context").validated(for: url))
        }
    }
    func testAnotherPagesRefreshDoesNotWithdrawSelectedSemanticMatch() {
        let chosen = item()
        var other = item(); other.id = "other"
        var state = SearchState(); state.setUsePageContext(true); state.update([chosen, other])
        state.setQuery("practice an instrument"); state.apply([chosen.id: 0.9, other.id: 0.1], ticket: state.ticket)
        state.select(chosen.id); let oldTicket = state.ticket
        other.pageContext?.controls = ["Changed control"]
        XCTAssertTrue(state.update([chosen, other]))
        XCTAssertEqual(state.selectedID, chosen.id); XCTAssertEqual(state.semantic[chosen.id], 0.9)
        XCTAssertFalse(state.apply([chosen.id: 0], ticket: oldTicket))
        state.discardProvisionalJudgments(); XCTAssertNil(state.semantic[other.id]); XCTAssertEqual(state.selectedID, chosen.id)
    }
    func testChangingSelectedPagesLabelsWaitsForFreshJudgmentButNavigationDoesNot() {
        var item = item(), state = SearchState(); state.setUsePageContext(true); state.update([item])
        state.setQuery("practice an instrument"); state.apply([item.id: 0.9], ticket: state.ticket); state.select(item.id)
        item.pageContext?.controls = ["Pause"]
        state.update([item]); XCTAssertEqual(state.selectedID, item.id); XCTAssertEqual(state.plausibleItems.count, 1)
        state.apply([item.id: 0.1], ticket: state.ticket); XCTAssertNil(state.selectedID)
        state.apply([item.id: 0.9], ticket: state.ticket); state.select(item.id)
        item.pageContext?.controls = ["Play"]
        state.update([item]); state.discardProvisionalJudgments(); XCTAssertNil(state.selectedID)
        state.apply([item.id: 0.9], ticket: state.ticket); state.select(item.id)
        item.url = "https://example.org/other"
        state.update([item]); XCTAssertTrue(state.semantic.isEmpty); XCTAssertNil(state.selectedID)
    }
    func testRichInventoriesSplitIntoBoundedRequestsWithoutDroppingItems() throws {
        let items = (0..<190).map { index -> WorkspaceItem in
            var item = self.item(); item.id = "item-\(index)"
            item.pageContext?.summary = String(repeating: "漢", count: 400)
            item.pageContext?.headings = (0..<6).map { String($0) + String(repeating: "漢", count: 79) }
            item.pageContext?.controls = (0..<10).map { String($0) + String(repeating: "漢", count: 39) }
            return item
        }
        let evidence = items.map { $0.evidence(includePageContext: true) }
        let batches = try DecisionBatch.batches(query: "practice", evidence: evidence)
        XCTAssertGreaterThan(batches.count, 2)
        XCTAssertEqual(batches.flatMap(\.evidence).map(\.id), items.map(\.id))
        for batch in batches { XCTAssertLessThanOrEqual(try batch.body().count, 128_000); XCTAssertLessThanOrEqual(batch.evidence.count, 96) }
    }
}
