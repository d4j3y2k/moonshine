import XCTest
@testable import MoonshineCore

final class ExposureLayoutTests: XCTestCase {
    func items(_ count: Int) -> [WorkspaceItem] {
        (0..<count).map { .init(id: "w\($0)", kind: .window, app: "Fixture", title: "Window", aspectRatio: [0.7, 1.4, 2.1][$0 % 3]) }
    }
    func testDenseLayoutHasNoOverlapsOrOutOfBoundsTiles() {
        for count in [1, 3, 9, 35, 95, 300] {
            let layout = ExposureLayout(items: items(count), width: 1200, height: 650)
            XCTAssertEqual(layout.tiles.count, count)
            for (index, tile) in layout.tiles.enumerated() {
                XCTAssertGreaterThan(tile.frame.width, 0); XCTAssertGreaterThan(tile.frame.height, 36)
                XCTAssertGreaterThanOrEqual(tile.frame.minX, -0.01); XCTAssertLessThanOrEqual(tile.frame.maxX, 1200.01)
                XCTAssertGreaterThanOrEqual(tile.frame.minY, -0.01); XCTAssertLessThanOrEqual(tile.frame.maxY, layout.height + 0.01)
                for other in layout.tiles.dropFirst(index + 1) { XCTAssertFalse(tile.frame.intersects(other.frame)) }
            }
        }
    }
    func testFilteringEnlargesSurvivorsWithoutChangingTheirIdentityOrOrder() {
        let all = items(35), remaining = Array(items(35)[10..<13])
        let full = ExposureLayout(items: all, width: 1200, height: 650)
        let filtered = ExposureLayout(items: remaining, width: 1200, height: 650)
        XCTAssertEqual(filtered.tiles.map(\.id), remaining.map(\.id))
        XCTAssertGreaterThan(filtered.tiles[0].frame.width, full.tiles[10].frame.width)
    }
    func testLocalAspectRatiosArePreserved() {
        let input = items(3), layout = ExposureLayout(items: input, width: 1200, height: 650)
        for (item, tile) in zip(input, layout.tiles) {
            XCTAssertEqual(tile.frame.width / (tile.frame.height - 36), item.aspectRatio!, accuracy: 0.001)
        }
    }
    func testEmptyAndInvalidGeometryRemainSafe() {
        XCTAssertTrue(ExposureLayout(items: [], width: 1200, height: 650).tiles.isEmpty)
        var item = items(1)[0]; item.aspectRatio = .nan
        let layout = ExposureLayout(items: [item], width: 0, height: 0)
        XCTAssertTrue(layout.tiles[0].frame.width.isFinite)
    }
}
