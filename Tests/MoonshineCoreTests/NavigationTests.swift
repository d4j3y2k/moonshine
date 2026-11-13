import XCTest
@testable import MoonshineCore

final class NavigationTests: XCTestCase {
    let navigation = OverviewNavigation(main: ["w0", "w1", "w2", "w3", "w4"], shelf: ["t0", "t1", "t2"], columns: 3)
    func testArrowsFollowGridAndHorizontalShelf() {
        XCTAssertEqual(navigation.destination(from: "w1", direction: .down), "w4")
        XCTAssertEqual(navigation.destination(from: "w2", direction: .down), "w4")
        XCTAssertEqual(navigation.destination(from: "w4", direction: .up), "w1")
        XCTAssertEqual(navigation.destination(from: "t0", direction: .right), "t1")
        XCTAssertEqual(navigation.destination(from: "t1", direction: .left), "t0")
    }
    func testCrossingShelfRestoresRememberedIdentity() {
        XCTAssertEqual(navigation.destination(from: "w3", direction: .down), "t0")
        XCTAssertEqual(navigation.destination(from: "t2", direction: .up, rememberedMain: "w3"), "w3")
        XCTAssertEqual(navigation.destination(from: "w4", direction: .right), "t0")
    }
    func testClosedRememberedIdentityCannotBeSelected() {
        XCTAssertEqual(navigation.destination(from: "t0", direction: .up, rememberedMain: "closed"), "w4")
        XCTAssertEqual(navigation.destination(from: "closed", direction: .down), "w0")
    }
    func testCyclingWrapsBothDirections() {
        XCTAssertEqual(navigation.cycle(from: "w4", backwards: false), "t0")
        XCTAssertEqual(navigation.cycle(from: "t0", backwards: true), "w4")
        XCTAssertEqual(navigation.cycle(from: "t2", backwards: false), "w0")
        XCTAssertEqual(navigation.cycle(from: "w0", backwards: true), "t2")
    }
    func testFilteredLayoutOnlyNavigatesItsSurvivors() {
        let filtered = OverviewNavigation(main: ["w1", "t2"], columns: 2)
        XCTAssertEqual(filtered.destination(from: "w1", direction: .right), "t2")
        XCTAssertEqual(filtered.destination(from: "t2", direction: .down), "t2")
        XCTAssertEqual(filtered.cycle(from: "t2", backwards: false), "w1")
    }
    func testEmptyResultsDoNotFallBackToUnrelatedItems() {
        let empty = OverviewNavigation(main: [], columns: 0)
        XCTAssertNil(empty.destination(from: nil, direction: .down))
        XCTAssertNil(empty.cycle(from: nil, backwards: false))
        let tabsOnly = OverviewNavigation(main: ["t0", "t1"], columns: 1)
        XCTAssertEqual(tabsOnly.destination(from: "t0", direction: .down), "t1")
    }
}
