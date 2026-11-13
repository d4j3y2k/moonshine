import Foundation
import CoreGraphics

/// Fits a stable sequence into an invisible grid, preserving each window's proportions.
/// Rows are centered, including the final partial row. Large inventories can scroll vertically.
public struct ExposureLayout: Sendable {
    public struct Tile: Identifiable, Sendable {
        public let id: String
        public let frame: CGRect
    }
    public let columns: Int
    public let tiles: [Tile]
    public let height: Double
    public init(items: [WorkspaceItem], width: Double, height availableHeight: Double) {
        let width = max(240, width), availableHeight = max(160, availableHeight)
        guard !items.isEmpty else { columns = 1; tiles = []; height = availableHeight; return }
        let gap = 28.0, label = 36.0
        let ratios = items.map { item in
            let value = item.kind == .browserTab ? 2.6 : item.aspectRatio ?? 1.5
            return value.isFinite ? min(2.7, max(0.55, value)) : 1.5
        }
        // Tabs have no picture to enlarge: they stay compact cards whatever space is free.
        let caps = items.map { $0.kind == .browserTab ? 300.0 : 550.0 }
        let maxColumns = max(1, min(items.count, Int((width + gap) / 180)))
        var bestColumns = 1, bestArea = -Double.infinity
        for c in 1...maxColumns {
            let rows = Int(ceil(Double(items.count) / Double(c)))
            let cellWidth = (width - gap * Double(c - 1)) / Double(c)
            let cellHeight = (availableHeight - gap * Double(rows - 1)) / Double(rows)
            let sizes = zip(ratios, caps).map { ratio, cap -> Double in
                let w = min(cellWidth, max(0, cellHeight - label) * ratio, cap)
                return w * w / ratio
            }
            let area = sizes.reduce(0, +)
            if area > bestArea { bestArea = area; bestColumns = c }
        }
        // When none of the arrangements are legible, prefer a scrollable grid over tiny targets.
        if bestArea / Double(items.count) < 9_000 { bestColumns = maxColumns }
        let columnCount = bestColumns
        columns = columnCount
        let rows = Int(ceil(Double(items.count) / Double(columnCount)))
        let cellWidth = (width - gap * Double(columnCount - 1)) / Double(columnCount)
        let cellHeight = max(132, (availableHeight - gap * Double(rows - 1)) / Double(rows))
        height = max(availableHeight, Double(rows) * cellHeight + Double(rows - 1) * gap)
        tiles = items.enumerated().map { index, item in
            let row = index / columnCount, column = index % columnCount
            let countInRow = min(columnCount, items.count - row * columnCount)
            let rowWidth = Double(countInRow) * cellWidth + Double(countInRow - 1) * gap
            let ratio = ratios[index]
            let previewWidth = min(cellWidth, (cellHeight - label) * ratio, caps[index])
            let tileHeight = previewWidth / ratio + label
            let x: Double = (width - rowWidth) / 2 + Double(column) * (cellWidth + gap) + (cellWidth - previewWidth) / 2
            let y: Double = Double(row) * (cellHeight + gap) + (cellHeight - tileHeight) / 2
            let frame = CGRect(x: x, y: y, width: previewWidth, height: tileHeight)
            return Tile(id: item.id, frame: frame)
        }
    }
}
