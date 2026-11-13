import Foundation

/// The main preview grid and the horizontal browser shelf share one identity-based selection.
public struct OverviewNavigation: Sendable {
    public enum Direction: Sendable { case left, right, up, down }
    public let main: [String]
    public let shelf: [String]
    public let columns: Int
    public init(main: [String], shelf: [String] = [], columns: Int) {
        self.main = main; self.shelf = shelf; self.columns = max(1, columns)
    }
    public func destination(from selected: String?, direction: Direction, rememberedMain: String? = nil) -> String? {
        if let selected, let index = main.firstIndex(of: selected) {
            switch direction {
            case .left: return main[max(0, index - 1)]
            case .right: return index + 1 < main.count ? main[index + 1] : shelf.first ?? selected
            case .up: return index >= columns ? main[index - columns] : selected
            case .down:
                if index / columns < (main.count - 1) / columns { return main[min(main.count - 1, index + columns)] }
                return shelf.first ?? selected
            }
        }
        if let selected, let index = shelf.firstIndex(of: selected) {
            switch direction {
            case .left: return index > 0 ? shelf[index - 1] : rememberedMain.flatMap { main.contains($0) ? $0 : nil } ?? main.last ?? selected
            case .right: return shelf[min(shelf.count - 1, index + 1)]
            case .up: return rememberedMain.flatMap { main.contains($0) ? $0 : nil } ?? main.last ?? selected
            case .down: return selected
            }
        }
        return main.first ?? shelf.first
    }
    public func cycle(from selected: String?, backwards: Bool) -> String? {
        let ids = main + shelf
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else { return backwards ? ids.last : ids.first }
        return ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count]
    }
}
