import Foundation
import CoreGraphics

/// Maps the image inside a fixed overview tile back to its real screen rectangle.
/// Captions remain part of the tile but are transparent at the source position.
/// Uniform scaling preserves the screenshot's aspect ratio throughout the zoom.
public struct WindowZoom: Equatable, Sendable {
    public let scale: Double
    public let offset: CGSize
    public static let identity = WindowZoom(scale: 1, offset: .zero)
    private init(scale: Double, offset: CGSize) { self.scale = scale; self.offset = offset }
    public init(source: CGRect, tile: CGRect, aspectRatio: Double, labelHeight: Double = 36) {
        let height = tile.height - labelHeight
        guard [source.minX, source.minY, source.width, source.height, tile.minX, tile.minY,
               tile.width, height, aspectRatio].allSatisfy(\.isFinite),
              source.width > 0, source.height > 0, tile.width > 0, height > 0, aspectRatio > 0 else {
            self = .identity; return
        }
        let imageWidth = min(tile.width, height * aspectRatio)
        let imageHeight = imageWidth / aspectRatio
        let xInset = (tile.width - imageWidth) / 2
        let yInset = (height - imageHeight) / 2
        let scale = min(source.width / imageWidth, source.height / imageHeight)
        self.init(scale: scale, offset: CGSize(
            width: source.minX - tile.minX - xInset * scale + (source.width - imageWidth * scale) / 2,
            height: source.minY - tile.minY - yInset * scale + (source.height - imageHeight * scale) / 2))
    }
}
