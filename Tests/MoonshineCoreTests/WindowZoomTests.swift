import XCTest
@testable import MoonshineCore

final class WindowZoomTests: XCTestCase {
    func testImageLandsOnRealWindowWithoutScalingTheCaptionIntoItsBounds() {
        for source in [CGRect(x: 80, y: 120, width: 1200, height: 750),
                       CGRect(x: -1400, y: -30, width: 900, height: 1000),
                       CGRect(x: 120, y: 80, width: 1800, height: 400)] {
            let tile = CGRect(x: 240, y: 160, width: 300, height: 216)
            let ratio = source.width / source.height
            let width = min(tile.width, (tile.height - 36) * ratio), height = width / ratio
            let zoom = WindowZoom(source: source, tile: tile, aspectRatio: ratio)
            let mapped = CGRect(x: tile.minX + zoom.offset.width + (tile.width - width) / 2 * zoom.scale,
                                y: tile.minY + zoom.offset.height + (tile.height - 36 - height) / 2 * zoom.scale,
                                width: width * zoom.scale, height: height * zoom.scale)
            XCTAssertEqual(mapped.minX, source.minX, accuracy: 0.001)
            XCTAssertEqual(mapped.minY, source.minY, accuracy: 0.001)
            XCTAssertEqual(mapped.width, source.width, accuracy: 0.001)
            XCTAssertEqual(mapped.height, source.height, accuracy: 0.001)
        }
    }
    func testDegenerateGeometryNeverCreatesAnInvalidTransform() {
        let source = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertEqual(WindowZoom(source: source, tile: .zero, aspectRatio: 1.5), .identity)
        XCTAssertEqual(WindowZoom(source: source, tile: source, aspectRatio: .nan), .identity)
        XCTAssertEqual(WindowZoom(source: .zero, tile: source, aspectRatio: 1.5), .identity)
    }
}
