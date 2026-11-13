import XCTest
@testable import MoonshineCore

final class SearchCacheTests: XCTestCase {
    func testPreparedMatchingTracksAllSourceChangesAndKeepsGeometryCurrent() {
        var item = WorkspaceItem(id: "same", kind: .browserTab, app: "Safari", title: "Piano", url: "https://example.org/music")
        var state = SearchState(); state.update([item]); state.setQuery("piano")
        XCTAssertEqual(state.plausibleItems.map(\.id), [item.id])
        item.title = "Notes"; state.update([item])
        XCTAssertTrue(state.plausibleItems.isEmpty)
        item.app = "Piano"; state.update([item])
        XCTAssertEqual(state.score(item), 1)
        item.app = "Safari"; item.url = "https://example.org/piano"; state.update([item])
        XCTAssertEqual(state.score(item), 0.85)
        let ticket = state.ticket
        item.screenFrame = ScreenFrame(x: 10, y: 20, width: 900, height: 600)
        XCTAssertFalse(state.update([item]))
        XCTAssertEqual(state.plausibleItems.first?.screenFrame, item.screenFrame)
        XCTAssertTrue(state.apply([item.id: 0], ticket: ticket))
        XCTAssertEqual(state.score(item), 0.85)
        state.update([]); state.update([WorkspaceItem(id: item.id, kind: .window, app: "Editor", title: "Budget")])
        XCTAssertTrue(state.plausibleItems.isEmpty)
        XCTAssertFalse(state.apply([item.id: 1], ticket: ticket))
    }
    func testUnchangedInventoryPreservesExplicitSelectionAndJudgments() {
        let items = [WorkspaceItem(id: "a", kind: .window, app: "Editor", title: "First"),
                     WorkspaceItem(id: "b", kind: .window, app: "Editor", title: "Second")]
        var state = SearchState(); state.update(items); state.setQuery("creative work")
        state.apply(["a": 0.8, "b": 0.9], ticket: state.ticket); state.select("b")
        let ticket = state.ticket
        for _ in 0..<10 { XCTAssertFalse(state.update(items)) }
        XCTAssertEqual(state.selectedID, "b"); XCTAssertEqual(state.ticket, ticket)
        XCTAssertEqual(state.plausibleItems.map(\.id), ["a", "b"])
    }
    func testBeginWithTransferredQueryResetsSelectionAndFiltersImmediately() {
        let items = [WorkspaceItem(id: "a", kind: .window, app: "Editor", title: "Piano"),
                     WorkspaceItem(id: "b", kind: .window, app: "Editor", title: "Budget")]
        var state = SearchState(); state.update(items); state.select("b")
        state.begin(query: "piano")
        XCTAssertEqual(state.query, "piano"); XCTAssertFalse(state.explicitSelection)
        XCTAssertEqual(state.selectedID, "a"); XCTAssertEqual(state.plausibleItems.map(\.id), ["a"])
    }
    func testSourceDigestRetainsSHA256WireFormat() {
        XCTAssertEqual(digest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(digest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
