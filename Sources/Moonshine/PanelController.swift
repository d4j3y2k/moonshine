import AppKit
import SwiftUI
import MoonshineCore

final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PanelController: NSObject, NSWindowDelegate {
    let model: AppModel
    let panel: OverviewPanel
    private weak var searchField: NSTextField?
    private var monitor: Any?
    private var previousApp: NSRunningApplication?
    private var settingsWindow: NSWindow?
    private var handoffPending = false
    private var handoffGeneration = 0
    private var pendingSearchCaret = false
    private var handoffStarted: LatencyTimer?
    var dispatchSearch: (SearchHandoff, @escaping (Bool) -> Void) -> Void = { SearchHandoffLauncher.open($0, to: .spleen, completion: $1) }
    private var hasOpened = false
    private var animatesZoom = false
    private var zoomGeneration = 0
    private var wallpaperURL: URL?
    var keyboardReady: Bool { searchField?.currentEditor() != nil && panel.firstResponder === searchField?.currentEditor() }
    func render(to url: URL) throws {
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
    init(model: AppModel) {
        self.model = model
        panel = OverviewPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Moonshine"; panel.identifier = NSUserInterfaceItemIdentifier("MoonshineOverview")
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Clear until the backdrop fades in, so the desktop shows through while windows zoom.
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let content = NSHostingView(rootView: Overview(model: model, searchReady: { [weak self] field in
            self?.searchField = field
            if self?.model.isPresented == true {
                self?.panel.makeFirstResponder(field)
                self?.placeSearchCaret()
            }
        }))
        content.sizingOptions = []; panel.contentView = content
        model.dismiss = { [weak self] in self?.dismiss(restore: false) }
        model.cancel = { [weak self] in self?.dismiss(restore: true) }
        model.recoverFocus = { [weak self] in self?.panel.makeKeyAndOrderFront(nil) }
        // Release the nonactivating panel's keyboard ownership before transferring
        // application focus. A failed handoff restores this same search via recoverFocus.
        model.prepareBrowserHandoff = { [weak self] in self?.panel.orderOut(nil) }
        model.switchSearch = { [weak self] in self?.switchSearch() }
        model.showSettings = { [weak self] in self?.settings() }
        model.finishOpeningForInput = { [weak self] in self?.finishOpeningForInput() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
            guard let self, self.model.isPresented, event.window === self.panel else { return event }
            if event.type == .mouseMoved { self.model.pointerHasMoved = true; return event }
            return self.handleKeyDown(event)
        }
    }
    @discardableResult func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard model.isPresented, !model.isClosing else { return event }
        if ((panel.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false) { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 53: dismiss(restore: true); return nil
            case 36, 76: if !event.isARepeat { model.activate() }; return nil
            case 123...126: model.move(keyCode: event.keyCode); return nil
            default: break
            }
        }
        if event.keyCode == 48 && (modifiers.isEmpty || modifiers == .shift) {
            if !event.isARepeat { switchSearch() }; return nil
        }
        if modifiers == .command && event.charactersIgnoringModifiers == "," { settings(); return nil }
        return event
    }
    func receiveSearch(_ request: SearchHandoff, focus: Bool = true) {
        handoffStarted = LatencyTimer()
        handoffGeneration += 1; handoffPending = false
        present(focus: focus, searchQuery: request.query)
        if let pid = request.returnPID,
           let app = NSRunningApplication(processIdentifier: pid),
           ![SearchHandoff.App.spleen.bundleID, SearchHandoff.App.moonshine.bundleID].contains(app.bundleIdentifier ?? "") {
            previousApp = app
        }
        pendingSearchCaret = true
        placeSearchCaret()
    }
    private func placeSearchCaret() {
        guard pendingSearchCaret, let searchField else { return }
        searchField.stringValue = model.search.query
        panel.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (model.search.query as NSString).length, length: 0)
            pendingSearchCaret = false
            if let elapsed = handoffStarted?.milliseconds {
                handoffStarted = nil
                Task { await Metrics.shared.record("handoff_to_keyboard", milliseconds: elapsed) }
            }
        }
    }
    func switchSearch() {
        guard model.isPresented, !model.isClosing, !model.activationPending, !handoffPending else { return }
        let query = model.search.query
        let wasKey = panel.isKeyWindow
        let request = SearchHandoff(query: query, returnPID: previousApp?.processIdentifier)
        handoffGeneration += 1
        let generation = handoffGeneration
        handoffPending = true
        panel.orderOut(nil)
        dispatchSearch(request) { [weak self] accepted in
            guard let self, self.handoffGeneration == generation else { return }
            self.handoffPending = false
            if accepted { self.dismiss(restore: false) }
            else {
                self.model.notice = "Couldn’t open Spleen. Open or install Spleen, then try Tab again."
                self.present(focus: wasKey)
                self.pendingSearchCaret = true; self.placeSearchCaret()
            }
        }
    }
    func toggle(focus: Bool = true) {
        if model.isPresented && !model.isClosing { dismiss(restore: true) }
        else { present(focus: focus) }
    }
    func present(focus: Bool = true, searchQuery: String? = nil) {
        let started = LatencyTimer()
        if model.isClosing { finishClosing() }
        let opening = !model.isPresented
        if !model.isPresented { previousApp = NSWorkspace.shared.frontmostApplication; model.open(query: searchQuery ?? "") }
        else if let searchQuery { model.queryChanged(searchQuery) }
        let modelMilliseconds = started.milliseconds
        var layoutMilliseconds = 0.0
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main!
        let available = screen.frame
        model.screenTopInset = max(screen.safeAreaInsets.top, available.maxY - screen.visibleFrame.maxY)
        // Local wallpaper only; never a screenshot of other apps and never remote inference input.
        if !model.demo, let url = NSWorkspace.shared.desktopImageURL(for: screen), url != wallpaperURL {
            wallpaperURL = url; model.wallpaper = NSImage(contentsOf: url)
        }
        panel.setFrame(available, display: false)
        panel.ignoresMouseEvents = false
        // Accessibility and CoreGraphics measure from the top-left of the primary display.
        model.panelOrigin = CGPoint(x: available.minX, y: (NSScreen.screens.first?.frame.maxY ?? available.maxY) - available.maxY)
        animatesZoom = focus
        if focus {
            panel.level = .floating
            if opening {
                // Mission Control-style: start with every visible window where it really is,
                // then let them settle into the grid as the backdrop comes up.
                zoomGeneration += 1
                let generation = zoomGeneration
                model.spread = false; model.isSettling = true
                let layoutTimer = LatencyTimer()
                panel.contentView?.layoutSubtreeIfNeeded()
                layoutMilliseconds = layoutTimer.milliseconds
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.zoomGeneration == generation else { return }
                    withAnimation(Self.reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.38, dampingFraction: 0.88)) { self.model.spread = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, self.zoomGeneration == generation else { return }
                        self.model.isSettling = false
                    }
                }
            }
            panel.makeKeyAndOrderFront(nil)
            if let searchField, !keyboardReady { panel.makeFirstResponder(searchField) }
        } else {
            model.spread = true; model.isSettling = false
            // Render fixtures behind the active app without intercepting a person's typing.
            panel.level = .normal; panel.orderBack(nil)
        }
        let metric = hasOpened ? "warm_open_dispatch" : "cold_open_dispatch"
        hasOpened = true
        let elapsed = started.milliseconds
        Task {
            await Metrics.shared.record(metric, milliseconds: elapsed)
            await Metrics.shared.record("open_model", milliseconds: modelMilliseconds)
            if opening && focus { await Metrics.shared.record("open_layout", milliseconds: layoutMilliseconds) }
        }
    }
    private func finishOpeningForInput() {
        guard model.isSettling, !model.isClosing else { return }
        zoomGeneration += 1
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { model.spread = true; model.isSettling = false }
    }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func dismiss(restore: Bool) {
        guard model.isPresented, !model.isClosing else { return }
        handoffGeneration += 1; handoffPending = false; pendingSearchCaret = false
        guard animatesZoom, panel.isVisible else {
            finishClosing()
            if restore, let previousApp, !previousApp.isTerminated { previousApp.activate(options: []) }
            return
        }
        // Fold back: windows return to where they really are while the backdrop clears,
        // and only then does the panel leave. Focus is handed back straight away.
        zoomGeneration += 1
        let generation = zoomGeneration
        model.isClosing = true; model.isSettling = true
        panel.ignoresMouseEvents = true
        withAnimation(Self.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.95)) { model.spread = false }
        if restore, let previousApp, !previousApp.isTerminated { previousApp.activate(options: []) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.reduceMotion ? 0.13 : 0.3)) { [weak self] in
            guard let self, self.zoomGeneration == generation else { return }
            self.finishClosing()
        }
    }
    private func finishClosing() {
        zoomGeneration += 1
        panel.orderOut(nil); model.close()
        model.isClosing = false; model.isSettling = false; model.spread = true
    }
    func windowDidResignKey(_ notification: Notification) {
        guard model.isPresented, !model.activationPending, !handoffPending else { return }
        // A click into another application dismisses without stealing its focus back.
        dismiss(restore: false)
    }
    func settings() {
        dismiss(restore: false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Moonshine Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var diagnostics = ""
    var body: some View {
        Form {
            Section("Overview") {
                Picker("Global shortcut", selection: $model.shortcutIndex) {
                    ForEach(HotKey.choices.indices, id: \.self) { Text(HotKey.choices[$0].label).tag($0) }
                }.onChange(of: model.shortcutIndex) { _, _ in model.saveSettings() }
                Toggle("Show cached window previews", isOn: $model.previewEnabled).onChange(of: model.previewEnabled) { _, _ in model.saveSettings() }
                HStack { Button("Enable Accessibility") { model.requestAccessibility() }; Button("Enable Screen Recording") { model.requestCapture() } }
                Text("Accessibility enables exact window focus. Screen Recording enables local previews. Browser windows use separate tab adapters so private tabs stay excluded.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser tabs") {
                Toggle("Discover Chrome tabs with Automation", isOn: $model.chromeEnabled).onChange(of: model.chromeEnabled) { _, _ in model.saveSettings() }
                Text("Safari uses the Moonshine browser extension. The extension can also connect individual Chrome profiles. Private tabs are always excluded.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.pairingCode, forType: .string) }
                    Button("Show extension folders") {
                        let url = Bundle.main.bundleURL.deletingLastPathComponent()
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Semantic search") {
                Toggle("Refine matches with OpenAI Decisions", isOn: $model.semanticEnabled).onChange(of: model.semanticEnabled) { _, _ in model.saveSettings() }
                Text("Sends your query, window/tab titles, app names, and web URLs without credentials, query strings, or fragments to OpenAI. No screenshots or browsing history are sent.").font(.caption).foregroundStyle(.secondary)
                HStack { Text(model.engine == nil ? "API key not configured" : "API key configured").font(.caption); Spacer(); Button("Choose key file…") { model.chooseKeyFile() } }
                Toggle("Use page context", isOn: $model.pageContextEnabled).onChange(of: model.pageContextEnabled) { _, _ in model.saveSettings() }
                Text("Adds page descriptions, headings, and button labels to matching and, when refinement is on, sends them to OpenAI. Enable each site in the updated browser extension first. No page body, form values, or screenshots are collected. Inspect a selected tab’s context in the overview.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Button("Show timing summary") { Task { diagnostics = await Metrics.shared.report() } }
                if !diagnostics.isEmpty { Text(diagnostics).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                Text("Timings and counts stay in memory. No title, URL, query, or screen history is logged.").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }.formStyle(.grouped).padding(8).frame(width: 580, height: 640)
    }
}
