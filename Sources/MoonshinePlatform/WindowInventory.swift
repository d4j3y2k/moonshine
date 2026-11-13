import AppKit
import ApplicationServices
import ScreenCaptureKit
import MoonshineCore

public enum NavigationError: Error, LocalizedError {
    case missing, permission, unsupported, failed, browserUnavailable
    public var errorDescription: String? {
        switch self {
        case .missing: return "That item has closed or changed. The workspace has been refreshed."
        case .permission: return "Enable Accessibility in Settings to focus a specific window."
        case .unsupported: return "This app does not expose a focusable window."
        case .failed: return "The app did not confirm the selected window. Try selecting it again."
        case .browserUnavailable: return "The browser connection is unavailable. Check browser access in Settings."
        }
    }
}

public struct RunningApp: Sendable {
    public let pid: Int32
    public let launch: Double
    public let name: String
    public let bundleID: String
    @MainActor public static func snapshot() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.compactMap {
            guard let start = ProcessLifetime.start(of: $0.processIdentifier) else { return nil }
            return RunningApp(pid: $0.processIdentifier, launch: start,
                       name: $0.localizedName ?? "Application", bundleID: $0.bundleIdentifier ?? "")
        }
    }
    public static func isBrowser(_ bundle: String) -> Bool {
        ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"].contains { bundle.hasPrefix($0) }
    }
}

public actor WindowInventory {
    private struct RetainedWindow { let app: RunningApp; let element: AXUIElement; var title: String; var frame: CGRect }
    private var retained: [String: RetainedWindow] = [:]
    private var previewCache: [String: (date: Date, image: CGImage)] = [:]
    private var unavailablePreviews: [String: Date] = [:]
    public init() {}
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private func attributes(_ element: AXUIElement) -> (frame: CGRect, title: String?, minimized: Bool) {
        let keys = [kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, keys, [], &raw)
        // Some older accessibility providers implement only the individual reads.
        let values: [AnyObject]
        if result == .notImplemented {
            values = [kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXMinimizedAttribute].map {
                value(element, $0) ?? kCFNull
            }
        } else {
            guard result == .success, let copied = raw as? [AnyObject], copied.count == 4 else { return (.zero, nil, false) }
            values = copied
        }
        var point = CGPoint.zero, size = CGSize.zero
        if CFGetTypeID(values[0]) == AXValueGetTypeID() { AXValueGetValue(values[0] as! AXValue, .cgPoint, &point) }
        if CFGetTypeID(values[1]) == AXValueGetTypeID() { AXValueGetValue(values[1] as! AXValue, .cgSize, &size) }
        return (CGRect(origin: point, size: size), values[2] as? String, values[3] as? Bool == true)
    }
    public func discover(apps: [RunningApp]) async -> [WorkspaceItem] {
        var next: [String: RetainedWindow] = [:], items: [WorkspaceItem] = []
        let accessible = AXIsProcessTrusted()
        let cgWindows = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // Front-to-back order of ordinary on-screen windows, browsers included, so position 0 is
        // whatever is in front. Bounds only: this needs no Screen Recording access and reads no titles.
        let own = ProcessInfo.processInfo.processIdentifier
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var stack: [(pid: Int32, number: Int, rect: CGRect, used: Bool)] = onScreen.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  let number = info[kCGWindowNumber as String] as? Int, let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 80, rect.height > 60 else { return nil }
            return (pid, number, rect, false)
        }
        // Geometry correlation is for ordering only, like previews; activation never depends on it.
        func position(pid: Int32, frame: CGRect) -> Int? {
            guard let index = stack.firstIndex(where: { !$0.used && $0.pid == pid && abs($0.rect.minX - frame.minX) < 4 && abs($0.rect.minY - frame.minY) < 4
                && abs($0.rect.width - frame.width) < 4 && abs($0.rect.height - frame.height) < 4 }) else { return nil }
            stack[index].used = true; return index
        }
        for app in apps where !RunningApp.isBrowser(app.bundleID) {
            // Let an exact-window activation get ahead of the remaining discovery work.
            await Task.yield()
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, 0.12)
            let windows = accessible ? (value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []) : []
            if !windows.isEmpty {
                for window in windows.prefix(80) {
                    await Task.yield()
                    AXUIElementSetMessagingTimeout(window, 0.08)
                    let details = attributes(window)
                    let windowFrame = details.frame
                    guard windowFrame.width > 80, windowFrame.height > 60 else { continue }
                    let title = details.title ?? app.name
                    let old = retained.first { $0.value.app.pid == app.pid && $0.value.app.launch == app.launch && CFEqual($0.value.element, window) }
                    let id = old?.key ?? UUID().uuidString
                    next[id] = RetainedWindow(app: app, element: window, title: title, frame: windowFrame)
                    let minimized = details.minimized
                    let place = minimized ? nil : position(pid: app.pid, frame: windowFrame)
                    items.append(WorkspaceItem(id: id, kind: .window, app: app.name, bundleID: app.bundleID,
                         title: title.isEmpty ? app.name : title, context: minimized ? "Minimized window" : "Window",
                         target: .accessibility(pid: app.pid, launch: app.launch, token: id), aspectRatio: windowFrame.width / windowFrame.height,
                         recency: place, screenFrame: place == nil ? nil : ScreenFrame(x: windowFrame.minX, y: windowFrame.minY, width: windowFrame.width, height: windowFrame.height)))
                }
            } else {
                for info in cgWindows where (info[kCGWindowOwnerPID as String] as? Int32) == app.pid && (info[kCGWindowLayer as String] as? Int) == 0 {
                    guard let number = info[kCGWindowNumber as String] as? Int,
                          let bounds = info[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 80, rect.height > 60 else { continue }
                    items.append(WorkspaceItem(id: "cg:\(app.pid):\(app.launch):\(number)", kind: .window,
                        app: app.name, bundleID: app.bundleID, title: info[kCGWindowName as String] as? String ?? app.name,
                        context: accessible ? "Focus unavailable" : "Accessibility needed", target: .unavailable, aspectRatio: rect.width / rect.height,
                        recency: stack.firstIndex { $0.number == number },
                        screenFrame: stack.contains { $0.number == number } ? ScreenFrame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) : nil))
                }
            }
        }
        retained = next
        // Most recent first; windows on other Spaces or minimized keep their order after those on screen.
        items = items.enumerated().sorted { a, b in
            let x = a.element.recency ?? Int.max, y = b.element.recency ?? Int.max
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
        let ids = Set(items.map(\.id)); previewCache = previewCache.filter { ids.contains($0.key) }
        unavailablePreviews = unavailablePreviews.filter { ids.contains($0.key) }
        return items
    }
    /// Matching title + geometry is used only for a thumbnail, never for activation.
    public func previews(items: [WorkspaceItem]) async -> [String: CGImage] {
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        var output: [String: CGImage] = [:]
        let candidates = items.prefix(48)
        for item in candidates {
            if let cached = previewCache[item.id] { output[item.id] = cached.image }
        }
        let stale = candidates.filter { item in
            // Minimized/off-Space/unavailable windows cannot produce a new still.
            guard item.screenFrame != nil, retained[item.id] != nil else { return false }
            if let attempted = unavailablePreviews[item.id], Date().timeIntervalSince(attempted) < 20 { return false }
            guard let cached = previewCache[item.id] else { return true }
            return Date().timeIntervalSince(cached.date) >= 20
        }
        // Warm openings use cached images without even enumerating capture sources.
        guard !stale.isEmpty, !Task.isCancelled,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              !Task.isCancelled else { return output }
        var wanted: [(id: String, window: SCWindow, configuration: SCStreamConfiguration)] = []
        for item in stale {
            guard let entry = retained[item.id] else { continue }
            let matches = content.windows.filter { window in
                window.owningApplication?.processID == entry.app.pid && window.windowLayer == 0 &&
                (window.title ?? "") == entry.title && abs(window.frame.minX - entry.frame.minX) < 4 &&
                abs(window.frame.minY - entry.frame.minY) < 4 && abs(window.frame.width - entry.frame.width) < 4 && abs(window.frame.height - entry.frame.height) < 4
            }
            guard matches.count == 1, let window = matches.first, window.isOnScreen else {
                unavailablePreviews[item.id] = Date(); continue
            }
            let configuration = SCStreamConfiguration()
            let ratio = window.frame.width / max(1, window.frame.height)
            // Large enough to stand in for the window itself while the overview zooms out.
            configuration.width = max(1, Int(min(960, 720 * ratio)))
            configuration.height = max(1, Int(Double(configuration.width) / ratio))
            configuration.showsCursor = false; configuration.scalesToFit = true
            wanted.append((item.id, window, configuration))
        }
        // Capture a few at a time so opening the overview is not one long serial wait.
        var start = 0
        while start < wanted.count && !Task.isCancelled {
            let batch = Array(wanted[start..<min(wanted.count, start + 8)]); start += 8
            await withTaskGroup(of: (String, CGImage?).self) { group in
                for entry in batch {
                    group.addTask {
                        (entry.id, try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: entry.window), configuration: entry.configuration))
                    }
                }
                for await (id, image) in group {
                    guard !Task.isCancelled, retained[id] != nil else { continue }
                    if let image {
                        output[id] = image; previewCache[id] = (Date(), image); unavailablePreviews.removeValue(forKey: id)
                    } else { unavailablePreviews[id] = Date() }
                }
            }
        }
        return output
    }
    public func activate(_ target: ActivationTarget) async throws {
        guard AXIsProcessTrusted() else { throw NavigationError.permission }
        guard case let .accessibility(pid, launch, token) = target, let entry = retained[token],
              entry.app.pid == pid, entry.app.launch == launch else { throw NavigationError.missing }
        let valid = ProcessLifetime.matches(pid: pid, start: launch)
        guard valid else { throw NavigationError.missing }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement], windows.contains(where: { CFEqual($0, entry.element) }) else { throw NavigationError.missing }
        AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        AXUIElementSetAttributeValue(entry.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString) == .success else { throw NavigationError.unsupported }
        // Most apps confirm immediately. Wait only while focus is actually pending,
        // retaining the former 120 ms settling window for slower applications.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        repeat {
            guard ProcessLifetime.matches(pid: pid, start: launch) else { throw NavigationError.missing }
            if let focused = value(application, kAXFocusedWindowAttribute), CFEqual(focused, entry.element) { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        } while true
        throw NavigationError.failed
    }
}
