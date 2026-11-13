import AppKit
import MoonshineCore

/// Tab selection and macOS application focus are separate operations. Retain the
/// existing browser process before the extension command, then complete its handoff.
@MainActor public struct BrowserApplication {
    private let application: NSRunningApplication
    private let start: Double

    public init(bundleID: String) throws {
        guard ["com.apple.Safari", "com.google.Chrome"].contains(bundleID) else { throw NavigationError.unsupported }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard running.count == 1, let application = running.first,
              let start = ProcessLifetime.start(of: application.processIdentifier) else { throw NavigationError.missing }
        self.application = application
        self.start = start
    }

    public func bringForward() async throws {
        try Task.checkCancellation()
        guard isCurrent else { throw NavigationError.missing }
        if !application.isActive || application.isHidden {
            await Metrics.shared.count("browser_ack_requires_foreground")
            try Task.checkCancellation()
            // Launch Services can reactivate an existing app from a nonactivating
            // panel, where NSRunningApplication.activate may reject the request.
            guard let url = application.bundleURL else { throw NavigationError.missing }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.promptsUserIfNeeded = false
            let activated = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            guard isCurrent, activated.processIdentifier == application.processIdentifier else { throw NavigationError.missing }
        }
        // Launch Services completion does not guarantee that focus has changed yet.
        for _ in 0..<50 {
            guard isCurrent else { throw NavigationError.missing }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier && !application.isHidden {
                await Metrics.shared.count("browser_foreground_confirmed")
                if CommandLine.arguments.contains("--inspect") {
                    FileHandle.standardError.write(Data("Browser handoff: foreground confirmed\n".utf8))
                }
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NavigationError.failed
    }

    private var isCurrent: Bool {
        !application.isTerminated && ProcessLifetime.matches(pid: application.processIdentifier, start: start)
    }
}
