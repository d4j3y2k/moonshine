import AppKit
import MoonshineCore

/// Deliberately synthetic local window imagery for layout checks; no desktop capture or user content.
@MainActor enum FixturePreviews {
    static func make(for items: [WorkspaceItem]) -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for (index, item) in items.filter({ $0.kind == .window }).enumerated() {
            if index % 7 == 6 { continue }
            let width = 640.0, height = width / (item.aspectRatio ?? 1.5)
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
            NSColor(calibratedWhite: 0.17, alpha: 1).setFill(); NSRect(x: 0, y: height - 32, width: width, height: 32).fill()
            for (offset, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: 12 + offset * 17, y: Int(height) - 22, width: 10, height: 10)).fill()
            }
            ("SYNTHETIC · " + item.app as NSString).draw(at: NSPoint(x: 90, y: height - 24), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.lightGray])
            if item.app == "Logic Pro" {
                for row in 0..<6 {
                    NSColor(calibratedWhite: row % 2 == 0 ? 0.14 : 0.12, alpha: 1).setFill()
                    NSRect(x: 0, y: 22 + row * 47, width: 640, height: 44).fill()
                    for column in 0..<4 {
                        NSColor(calibratedHue: CGFloat(row) * 0.09 + 0.28, saturation: 0.5, brightness: 0.65, alpha: 1).setFill()
                        NSBezierPath(roundedRect: NSRect(x: 125 + column * 122, y: 28 + row * 47, width: 110, height: 32), xRadius: 3, yRadius: 3).fill()
                    }
                }
            } else if item.app == "Notes" {
                NSColor(calibratedWhite: 0.92, alpha: 1).setFill(); NSRect(x: 130, y: 20, width: 480, height: height - 72).fill()
                ("Website redesign\n\nTypography\n\nNavigation\n\nA clearer place to start." as NSString).draw(in: NSRect(x: 160, y: 60, width: 420, height: height - 130), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray])
            } else {
                NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 125, height: height - 32).fill()
                ("Moonshine\n\nSources\n  Overview\n  Search\n  Windows\n\nTests" as NSString).draw(in: NSRect(x: 14, y: 20, width: 105, height: height - 70), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.lightGray])
                ("struct Workspace {\n\n    let windows: [Window]\n    let tabs: [BrowserTab]\n\n    func find(_ query: String) {\n        // An overview of open work\n        let matches = search(query)\n        present(matches)\n    }\n}" as NSString).draw(in: NSRect(x: 150, y: 20, width: 470, height: height - 70), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.93, alpha: 1)])
            }
            image.unlockFocus(); images[item.id] = image
        }
        return images
    }
}
