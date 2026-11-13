import Foundation
import AppKit
import MoonshineCore

public actor ChromeAdapter {
    public init() {}
    public func discover(app: RunningApp) async throws -> [WorkspaceItem] {
        let script = """
        const app = Application('com.google.Chrome');
        const output = [];
        for (const w of app.windows()) {
          if (w.mode() !== 'normal') continue;
          const wid = w.id();
          for (const t of w.tabs()) {
            output.push({id: Number(t.id()), window: Number(wid), title: t.title(), url: t.url()});
          }
        }
        JSON.stringify(output);
        """
        struct Tab: Decodable { let id: Int; let window: Int; let title: String; let url: String }
        let data = try await ScriptRunner.run(script)
        let tabs = try JSONDecoder().decode([Tab].self, from: data)
        return tabs.prefix(2000).map { tab in
            WorkspaceItem(id: "chrome:\(app.pid):\(app.launch):\(tab.id)", kind: .browserTab,
                          app: "Chrome", bundleID: "com.google.Chrome", title: tab.title, url: tab.url,
                          context: "Window \(tab.window)", target: .chrome(pid: app.pid, launch: app.launch, tabID: tab.id))
        }
    }
    public func activate(_ target: ActivationTarget) async throws {
        guard case let .chrome(pid, launch, tabID) = target else { throw NavigationError.missing }
        let valid = ProcessLifetime.matches(pid: pid, start: launch)
        guard valid else { throw NavigationError.missing }
        // Numeric IDs only. Re-resolve the tab inside its current window at dispatch time.
        let script = """
        const app = Application('com.google.Chrome');
        let found = false;
        for (const w of app.windows()) {
          if (w.mode() !== 'normal') continue;
          const tabs = w.tabs();
          for (let i = 0; i < tabs.length; i++) {
            if (Number(tabs[i].id()) !== \(tabID)) continue;
            w.activeTabIndex = i + 1;
            w.minimized = false;
            w.index = 1;
            app.activate();
            found = Number(w.activeTab().id()) === \(tabID);
            break;
          }
          if (found) break;
        }
        JSON.stringify({found: found});
        """
        let data = try await ScriptRunner.run(script)
        guard (try JSONSerialization.jsonObject(with: data) as? [String: Bool])?["found"] == true else { throw NavigationError.missing }
    }
}

public enum ScriptRunner {
    public static func run(_ source: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process(), output = Pipe(), errors = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-l", "JavaScript", "-e", source]
                task.standardOutput = output; task.standardError = errors
                do { try task.run() } catch { continuation.resume(throwing: NavigationError.browserUnavailable); return }
                let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
                // Drain while the process runs; large inventories must not block a full pipe.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit(); timeout.cancel()
                guard task.terminationStatus == 0, data.count < 2_000_000 else {
                    continuation.resume(throwing: NavigationError.browserUnavailable); return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
