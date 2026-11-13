import XCTest
@testable import MoonshineCore

final class SearchTests: XCTestCase {
    let a = WorkspaceItem(id: "a", kind: .window, app: "Editor", title: "Orphne")
    let b = WorkspaceItem(id: "b", kind: .browserTab, app: "Safari", title: "Envelope documentation")
    func state() -> SearchState { var state = SearchState(); state.update([a, b]); return state }
    func testOldQueryCannotReplaceNewText() {
        var state = state(); state.setQuery("music"); let ticket = state.ticket
        state.setQuery("docs"); XCTAssertFalse(state.apply(["a": 1], ticket: ticket)); XCTAssertTrue(state.semantic.isEmpty)
    }
    func testContentChangesInvalidatePendingJudgment() {
        var state = state(); state.setQuery("music"); let ticket = state.ticket
        var changed = a; changed.title = "Unrelated content"
        state.update([changed, b]); XCTAssertFalse(state.apply(["a": 1], ticket: ticket))
    }
    func testClosedAndRecreatedTargetDoesNotInheritResponse() {
        var state = state(); state.setQuery("music"); let ticket = state.ticket
        var recreated = a; recreated.id = "new-lifetime"
        state.update([recreated, b]); XCTAssertFalse(state.apply(["a": 1], ticket: ticket))
    }
    func testExplicitSelectionSurvivesQueryAndSemanticUpdates() {
        var state = state(); state.select("b"); state.setQuery("documentation")
        XCTAssertTrue(state.apply(["a": 1, "b": 0], ticket: state.ticket)); XCTAssertEqual(state.selectedID, "b")
        state.setQuery(""); XCTAssertEqual(state.selectedID, "b")
    }
    func testFilteringRemovesUnrelatedItemsFromNavigation() {
        var state = state(); state.setQuery("documentation")
        XCTAssertEqual(state.plausibleItems.map(\.id), ["b"])
        state.move(-1, among: ["a", "b"]); XCTAssertEqual(state.selectedID, "b")
        state.select("a"); XCTAssertEqual(state.selectedID, "b")
        state.setQuery("not-a-real-target"); XCTAssertTrue(state.plausibleItems.isEmpty)
        XCTAssertNil(state.selectedID); state.move(1); XCTAssertNil(state.selectedID)
        state.setQuery(""); XCTAssertEqual(state.plausibleItems.count, 2)
    }
    func testRefinementCanRecoverCandidatesHiddenByLocalMatching() {
        var state = state(); state.setQuery("sound shaping")
        XCTAssertTrue(state.plausibleItems.isEmpty); XCTAssertEqual(state.ticket.evidence.count, 2)
        state.apply(["a": 0.1, "b": 0.8], ticket: state.ticket)
        XCTAssertEqual(state.plausibleItems.map(\.id), ["b"])
    }
    func testFilteredExplicitSelectionBecomesEmptyInsteadOfRetargeting() {
        var state = state(); state.setQuery("sound shaping")
        state.apply(["a": 0.6, "b": 0.8], ticket: state.ticket); state.select("a")
        state.apply(["a": 0.1, "b": 0.9], ticket: state.ticket)
        XCTAssertNil(state.selectedID); XCTAssertTrue(state.explicitSelection)
        XCTAssertEqual(state.plausibleItems.map(\.id), ["b"])
        state.move(1); XCTAssertEqual(state.selectedID, "b")
    }
    func testGeometryChangesDoNotInvalidateSemanticEvidence() {
        var state = state(); state.setQuery("music"); let ticket = state.ticket
        var changed = a; changed.aspectRatio = 0.65
        XCTAssertFalse(state.update([changed, b])); XCTAssertTrue(state.apply(["a": 0.8], ticket: ticket))
    }
    func testClosedExplicitSelectionDoesNotActivateNewIndexOccupant() {
        var state = state(); state.select("a"); state.update([b]); XCTAssertNil(state.selected)
        state.setQuery("documentation"); XCTAssertNil(state.selected)
        state.move(1); XCTAssertEqual(state.selectedID, "b")
    }
    func testRefreshAndScoresKeepSpatialOrder() {
        var state = state(); state.setQuery("music"); state.update([b, a]); state.apply(["b": 1], ticket: state.ticket)
        XCTAssertEqual(state.items.map(\.id), ["a", "b"])
    }
    func testNoMatchAndBackspaceKeepAlternativesReachable() {
        var state = state(); state.setQuery("there is no such item"); state.apply(["a": 0.01, "b": 0], ticket: state.ticket)
        XCTAssertNil(state.selectedID); XCTAssertEqual(state.items.count, 2)
        state.setQuery(""); XCTAssertEqual(state.selectedID, "a"); XCTAssertEqual(state.score(b), 1)
    }
    func testLocalExactMatchCannotBeRemovedByLowSemanticScore() {
        var state = state(); state.setQuery("Orphne"); state.apply(["a": 0], ticket: state.ticket)
        XCTAssertEqual(state.selectedID, "a"); XCTAssertEqual(state.score(a), 1)
    }
    func testUnrelatedContextDoesNotInvalidateEvidence() {
        var state = state(); state.setQuery("music"); let ticket = state.ticket
        var changed = a; changed.context = "Cached preview changed"
        XCTAssertFalse(state.update([changed, b])); XCTAssertTrue(state.apply(["a": 0.8], ticket: ticket))
    }
    func testRejectedUnknownAndNonFiniteValuesAreAtomic() {
        var state = state(); state.setQuery("music")
        XCTAssertFalse(state.apply(["a": 0.9, "invented": 1], ticket: state.ticket)); XCTAssertTrue(state.semantic.isEmpty)
        XCTAssertFalse(state.apply(["a": .nan], ticket: state.ticket)); XCTAssertTrue(state.semantic.isEmpty)
    }
    func testDuplicateTitlesKeepSeparateSelectionTargets() {
        var other = a; other.id = "other"
        var state = SearchState(); state.update([a, other]); state.select("other")
        state.update([other, a]); XCTAssertEqual(state.selectedID, "other")
    }
    func testInferenceURLRemovesSensitiveComponents() {
        var item = b; item.url = "https://user:password@example.org/reference?q=secret#fragment"
        XCTAssertEqual(item.inferenceURL, "https://example.org/reference")
        item.url = "file:///Users/me/private.txt"; XCTAssertNil(item.inferenceURL)
    }
    func testQueryStringNavigationInvalidatesResponseWithoutTransmittingIt() {
        var first = b; first.url = "https://example.org/?document=one"
        var state = SearchState(); state.update([first]); state.setQuery("music"); let ticket = state.ticket
        var second = first; second.url = "https://example.org/?document=two"
        XCTAssertEqual(first.inferenceURL, second.inferenceURL)
        state.update([second]); XCTAssertFalse(state.apply(["b": 0.9], ticket: ticket))
    }
    func testResultsAreRankedByLocalMatchQualityInStableOrder() {
        let items = [
            WorkspaceItem(id: "url", kind: .browserTab, app: "Safari", title: "Reference", url: "https://example.org/notes"),
            WorkspaceItem(id: "inside", kind: .window, app: "Editor", title: "Footnotes draft"),
            WorkspaceItem(id: "word", kind: .window, app: "Editor", title: "Meeting notes"),
            WorkspaceItem(id: "prefix", kind: .window, app: "Editor", title: "Notes for Friday"),
            WorkspaceItem(id: "exact", kind: .window, app: "Notes", title: "Shopping"),
            WorkspaceItem(id: "word2", kind: .window, app: "Editor", title: "Release-notes.md"),
            WorkspaceItem(id: "none", kind: .window, app: "Editor", title: "Budget")
        ]
        var state = SearchState(); state.update(items); state.setQuery("notes")
        XCTAssertEqual(state.plausibleItems.map(\.id), ["exact", "prefix", "word", "word2", "inside", "url"])
        XCTAssertEqual(state.selectedID, "exact")
        XCTAssertEqual(state.items.map(\.id), items.map(\.id))
    }
    func testRecoveredItemsFollowLocalMatchesWithoutProbabilityOrdering() {
        let c = WorkspaceItem(id: "c", kind: .window, app: "Mixer", title: "Session")
        var state = SearchState(); state.update([c, a, b]); state.setQuery("envelope")
        state.apply(["a": 0.5, "c": 0.99], ticket: state.ticket)
        XCTAssertEqual(state.plausibleItems.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(state.selectedID, "b")
    }
    func testInitialsAndTyposMatchButRankBelowRealMatches() {
        let code = WorkspaceItem(id: "code", kind: .window, app: "Visual Studio Code", title: "main.swift")
        let docs = WorkspaceItem(id: "docs", kind: .browserTab, app: "Safari", title: "Envelope documentation")
        XCTAssertEqual(LocalMatch.score(query: "vsc", item: code), 0.6)
        XCTAssertEqual(LocalMatch.score(query: "documnetation", item: docs), 0.55)
        XCTAssertEqual(LocalMatch.score(query: "envelpe docs", item: docs), 0)
        XCTAssertEqual(LocalMatch.score(query: "envelpe documentation", item: docs), 0.55)
        XCTAssertEqual(LocalMatch.score(query: "docum", item: docs), 0.96)
        XCTAssertEqual(LocalMatch.score(query: "dcoum", item: docs), 0.55)
        // Short words stay strict: one edit would turn "mail" into "main".
        XCTAssertEqual(LocalMatch.score(query: "mail", item: code), 0)
        XCTAssertEqual(LocalMatch.score(query: "visual", item: code), 0.9)
    }
    func testIdleInventoryFollowsRecencyAndStartsOnThePreviousWindow() {
        var front = a, behind = b; front.recency = 0; behind.recency = 1
        var state = SearchState(); state.update([front, behind])
        XCTAssertEqual(state.selectedID, "b")
        behind.recency = 0; front.recency = 1
        state.update([behind, front])
        XCTAssertEqual(state.items.map(\.id), ["b", "a"]); XCTAssertEqual(state.selectedID, "a")
        // Once something is chosen or typed, order holds still.
        state.select("a"); front.recency = 0; behind.recency = 1; state.update([front, behind])
        XCTAssertEqual(state.items.map(\.id), ["b", "a"]); XCTAssertEqual(state.selectedID, "a")
        // A browser in front leaves no window at position 0, so the first one is the way back.
        var only = SearchState(); only.update([behind]); XCTAssertEqual(only.selectedID, "b")
    }
    func testRecencyDoesNotEnterEvidence() {
        var moved = a; moved.recency = 3
        XCTAssertEqual(moved.evidence, a.evidence)
    }
}
