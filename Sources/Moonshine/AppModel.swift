import AppKit
import SwiftUI
import MoonshineCore
import MoonshinePlatform

@MainActor final class AppModel: ObservableObject {
    @Published var search = SearchState()
    @Published var previews: [String: NSImage] = [:]
    @Published var status = "Local workspace"
    @Published var notice: String?
    @Published var isPresented = false
    @Published var presentationID: UInt64 = 0
    private(set) var isRefreshing = false
    @Published var settingsRevision = 0
    @Published var semanticEnabled = UserDefaults.standard.bool(forKey: "semanticEnabled")
    @Published var pageContextEnabled = UserDefaults.standard.bool(forKey: "pageContextEnabled")
    @Published var chromeEnabled = UserDefaults.standard.bool(forKey: "chromeEnabled")
    @Published var previewEnabled = UserDefaults.standard.object(forKey: "previewEnabled") as? Bool ?? true
    @Published var shortcutIndex = UserDefaults.standard.integer(forKey: "shortcutIndex")
    @Published var browsingTabs = false
    @Published var canvasSize = CGSize(width: 1100, height: 600)
    @Published var screenTopInset: CGFloat = 0
    @Published var wallpaper: NSImage?
    @Published var isRefining = false
    /// false while windows sit at their real screen positions (the start of opening, the end of closing).
    @Published var spread = true
    /// The window being opened lands on top while the overview folds away.
    @Published var isClosing = false
    /// True while tiles are in flight, so they may pass over the header and footer.
    @Published var isSettling = false {
        didSet {
            guard isSettling != oldValue else { return }
            if isSettling { cancelPreviews() }
            else { finishVisualTransition() }
        }
    }
    @Published var canvasOrigin = CGPoint.zero
    /// Top-left of the overview panel in global top-left display points.
    var panelOrigin = CGPoint.zero
    /// A window's real frame expressed in the canvas's coordinates, with room for its label.
    func sourceFrame(for item: WorkspaceItem) -> CGRect? {
        guard item.kind == .window, let frame = item.screenFrame else { return nil }
        return CGRect(x: frame.x - panelOrigin.x - canvasOrigin.x, y: frame.y - panelOrigin.y - canvasOrigin.y, width: frame.width, height: frame.height + 36)
    }
    @Published var refinementMilliseconds: Double?
    let windows = WindowInventory()
    let chrome = ChromeAdapter()
    let bridge: BrowserBridge
    let pairingCode: String
    let demo: Bool
    var liveDemoEnabled = false
    var liveDemo: Bool { demo && liveDemoEnabled }
    var engine: SemanticEngine?
    private var semanticTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    private let activation: ((WorkspaceItem) async throws -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration: UInt64 = 0
    private var previewSources: [String: CGImage] = [:]
    private var bridgeTask: Task<Void, Never>?
    private var nativeItems: [WorkspaceItem] = []
    private var fallbackTabs: [WorkspaceItem] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var activationPending = false
    var pointerHasMoved = false
    private var rememberedMain: String?
    var recoverFocus: (() -> Void)?
    var prepareBrowserHandoff: (() -> Void)?
    private var pendingRefresh = false
    private var deferredInventory: [WorkspaceItem]?
    var finishOpeningForInput: (() -> Void)?
    var dismiss: (() -> Void)?
    var cancel: (() -> Void)?
    var switchSearch: (() -> Void)?
    var showSettings: (() -> Void)?
    var shortcutChanged: (() -> Void)?
    var keyPath: String? { UserDefaults.standard.string(forKey: "keyPath") ?? Bundle.main.object(forInfoDictionaryKey: "MoonshineDevelopmentKeyPath") as? String }
    init(activation: ((WorkspaceItem) async throws -> Void)? = nil) {
        self.activation = activation
        demo = CommandLine.arguments.contains("--demo")
        liveDemoEnabled = demo && CommandLine.arguments.contains("--live-decisions") && !CommandLine.arguments.contains("--self-test")
        // Synthetic demos and native checks never read or rewrite the live pairing identity.
        pairingCode = (demo ? nil : UserDefaults.standard.string(forKey: "bridgeToken")) ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        if !demo { UserDefaults.standard.set(pairingCode, forKey: "bridgeToken") }
        bridge = BrowserBridge(token: pairingCode)
        configureSemantic()
        search.setUsePageContext(pageContextEnabled)
        if demo { search.update(Self.fixtures); previews = FixturePreviews.make(for: Self.fixtures); status = "Synthetic workspace · activation disabled"; return }
        Task { do { try await bridge.start() } catch { notice = "Browser bridge could not start. Port \(BrowserBridge.port) may be in use." } }
        bridgeTask = Task { [weak self, bridge] in
            for await _ in await bridge.inventoryUpdates() {
                guard let self else { return }
                let started = LatencyTimer()
                self.mergeInventory(await bridge.inventory())
                await Metrics.shared.record("bridge_inventory_apply", milliseconds: started.milliseconds)
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }
    var windowItems: [WorkspaceItem] { search.items.filter { $0.kind == .window } }
    var allTabs: [WorkspaceItem] { search.items.filter { $0.kind == .browserTab } }
    var mainItems: [WorkspaceItem] { search.isSearching ? search.plausibleItems : browsingTabs ? allTabs : windowItems }
    var shelfItems: [WorkspaceItem] { search.isSearching || browsingTabs ? [] : allTabs }
    var layout: ExposureLayout { ExposureLayout(items: mainItems, width: canvasSize.width, height: canvasSize.height) }
    var navigation: OverviewNavigation { .init(main: mainItems.map(\.id), shelf: shelfItems.map(\.id), columns: layout.columns) }
    var selectableIDs: Set<String> { Set(mainItems.map(\.id) + shelfItems.map(\.id)) }
    var matchingCount: Int { search.plausibleItems.count }
    func open(query: String = "") {
        isPresented = true; pointerHasMoved = false; rememberedMain = nil; browsingTabs = false
        presentationID &+= 1
        search.begin(query: query); refinementMilliseconds = nil; isRefining = false
        status = demo ? "Synthetic workspace · activation disabled" : "Type to find something open"
        if search.isSearching { refine() }
        refresh()
    }
    func cancelActivation() {
        activationGeneration &+= 1; activationTask?.cancel(); activationTask = nil; activationPending = false
    }
    func close() {
        cancelActivation()
        cancelPreviews(); isPresented = false; semanticTask?.cancel(); semanticTask = nil; isRefining = false; search.setQuery("")
    }
    func queryChanged(_ value: String) {
        finishOpeningForInput?()
        pointerHasMoved = false; browsingTabs = false; refinementMilliseconds = nil
        let start = LatencyTimer(); search.setQuery(value)
        let elapsed = start.milliseconds
        Task { await Metrics.shared.record("local_result", milliseconds: elapsed) }
        refine()
    }
    func showTabs(_ show: Bool) {
        finishOpeningForInput?()
        semanticTask?.cancel(); isRefining = false; pointerHasMoved = false
        browsingTabs = show; search.begin(); refinementMilliseconds = nil
        search.restrictSelection(to: mainItems.map(\.id))
        status = demo ? "Synthetic workspace · activation disabled" : "Type to search windows and tabs"
    }
    func select(_ id: String) {
        guard selectableIDs.contains(id) else { return }
        guard search.selectedID != id || !search.explicitSelection else { return }
        search.select(id)
        if mainItems.contains(where: { $0.id == id }) { rememberedMain = id }
    }
    func move(keyCode: UInt16) {
        pointerHasMoved = false
        if let id = search.selectedID, mainItems.contains(where: { $0.id == id }) { rememberedMain = id }
        let direction: OverviewNavigation.Direction = keyCode == 123 ? .left : keyCode == 124 ? .right : keyCode == 125 ? .down : .up
        if let id = navigation.destination(from: search.selectedID, direction: direction, rememberedMain: rememberedMain) { select(id) }
    }
    func cycle(backwards: Bool) {
        pointerHasMoved = false
        if let id = navigation.cycle(from: search.selectedID, backwards: backwards) { select(id) }
    }
    func refresh() {
        guard !demo else { return }
        guard refreshTask == nil else { pendingRefresh = true; return }
        isRefreshing = true
        refreshTask = Task {
            // Snapshot after the caller returns, so opening/keyboard dispatch does not
            // synchronously enumerate processes before the panel can become key.
            let apps = RunningApp.snapshot(), chromeEnabled = chromeEnabled
            let inventoryTimer = LatencyTimer()
            let native = await windows.discover(apps: apps)
            await Metrics.shared.record("inventory_native", milliseconds: inventoryTimer.milliseconds)
            nativeItems = native
            mergeInventory(await bridge.inventory())
            refreshPreviews()
            let bridged = await bridge.inventory()
            var tabs: [WorkspaceItem] = []
            if chromeEnabled, !bridged.contains(where: { $0.app == "Chrome" }), let app = apps.first(where: { $0.bundleID == "com.google.Chrome" }) {
                do { tabs = try await chrome.discover(app: app) }
                catch { if isPresented { notice = "Chrome access is unavailable. Enable it in macOS Automation settings, or use the browser extension." } }
            }
            fallbackTabs = tabs
            // Re-read after a potentially slow native/fallback scan; never overwrite
            // a newer browser event with the earlier snapshot.
            mergeInventory(await bridge.inventory())
            isRefreshing = false
            refreshPreviews()
            refreshTask = nil
            if pendingRefresh { pendingRefresh = false; refresh() }
        }
    }
    private func cancelPreviews() {
        previewGeneration &+= 1; previewTask?.cancel(); previewTask = nil
    }
    private func refreshPreviews() {
        guard !demo else { return }
        guard isPresented, !isClosing, !isSettling, !activationPending, previewEnabled else {
            cancelPreviews()
            if !previewEnabled && !previews.isEmpty { previews = [:]; previewSources = [:] }
            return
        }
        guard previewTask == nil else { return }
        let generation = previewGeneration, native = nativeItems
        previewTask = Task {
            let started = LatencyTimer()
            let images = await windows.previews(items: native)
            guard !Task.isCancelled, previewGeneration == generation else { return }
            await Metrics.shared.record("preview_batch", milliseconds: started.milliseconds)
            guard !Task.isCancelled, previewGeneration == generation, isPresented, !isSettling else { return }
            let ids = Set(search.items.map(\.id))
            // Preserve the NSImage wrappers when the underlying capture is unchanged.
            var next = previews.filter { ids.contains($0.key) && images[$0.key] != nil }
            var changed = next.count != previews.count
            for (id, image) in images where ids.contains(id) {
                if next[id] != nil, let current = previewSources[id], current === image { continue }
                next[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)); changed = true
            }
            previewSources = images.filter { ids.contains($0.key) }
            if changed { previews = next }
            previewTask = nil
        }
    }
    func mergeInventory(_ bridged: [WorkspaceItem]) {
        let tabs = bridged.contains(where: { $0.app == "Chrome" }) ? [] : fallbackTabs
        let incoming = nativeItems + tabs + bridged
        // Freeze the moving targets, not keyboard input. The latest snapshot wins.
        if isSettling { deferredInventory = incoming; return }
        applyInventory(incoming)
    }
    private func finishVisualTransition() {
        if let incoming = deferredInventory {
            deferredInventory = nil
            applyInventory(incoming)
        }
        refreshPreviews()
    }
    private func applyInventory(_ incoming: [WorkspaceItem]) {
        // A periodic scan with identical data must not republish the entire canvas.
        guard incoming != search.items || search.usePageContext else { return }
        pointerHasMoved = false
        let changed = search.update(incoming)
        if browsingTabs { search.restrictSelection(to: allTabs.map(\.id)) }
        let ids = Set(search.items.map(\.id))
        if previews.keys.contains(where: { !ids.contains($0) }) { previews = previews.filter { ids.contains($0.key) } }
        if changed && isPresented { refine() }
    }
    func refine() {
        semanticTask?.cancel(); isRefining = false
        guard search.isSearching else { status = demo ? "Synthetic workspace · activation disabled" : "Type to find something open"; return }
        guard (!demo || liveDemo), (semanticEnabled || liveDemo), let engine, !search.items.isEmpty else { search.discardProvisionalJudgments(); status = "Local search"; return }
        let ticket = search.ticket, started = LatencyTimer()
        status = "Refining with Decisions…"; isRefining = true
        semanticTask = Task {
            do {
                // Serialization and cache lookup run on the engine actor, off the UI.
                let batches = try await engine.batches(query: ticket.query, evidence: ticket.evidence)
                let cached = try await engine.cached(batches)
                try Task.checkCancellation()
                if let cached {
                    for result in cached {
                        guard search.apply(result, ticket: ticket) else { await Metrics.shared.count("stale_response_rejected"); return }
                    }
                    await Metrics.shared.count("query_cache_hit")
                } else {
                    // Preserve debounce for new remote work. Every candidate is evaluated.
                    try await Task.sleep(for: .milliseconds(180))
                    for batch in batches {
                        try Task.checkCancellation()
                        let result = try await engine.evaluate(batch)
                        try Task.checkCancellation()
                        pointerHasMoved = false
                        guard search.apply(result, ticket: ticket) else { await Metrics.shared.count("stale_response_rejected"); return }
                    }
                }
                search.discardProvisionalJudgments()
                isRefining = false
                let elapsed = started.milliseconds
                refinementMilliseconds = elapsed
                status = liveDemo ? "Synthetic workspace · live Decisions" : "Refined with Decisions"
                await Metrics.shared.record("query_to_semantic", milliseconds: elapsed)
                await Metrics.shared.record(cached == nil ? "query_to_semantic_remote" : "query_to_semantic_cached", milliseconds: elapsed)
            } catch is CancellationError { await Metrics.shared.count("obsolete_work_cancelled") }
            catch {
                guard search.ticket == ticket else { await Metrics.shared.count("stale_response_rejected"); return }
                search.discardProvisionalJudgments()
                isRefining = false; status = "Local search · Decisions unavailable"
                // No response body or query enters diagnostics.
                await Metrics.shared.count("semantic_failure")
            }
        }
    }
    func activate(_ id: String? = nil) {
        if let id { select(id) }
        guard isPresented, !activationPending, let item = search.selected, selectableIDs.contains(item.id) else { return }
        if demo && activation == nil { notice = "This is a synthetic fixture. Open the real workspace from the menu bar."; return }
        activationPending = true; cancelPreviews()
        activationGeneration &+= 1
        let generation = activationGeneration
        let activationTimer = LatencyTimer()
        activationTask = Task {
            defer {
                if activationGeneration == generation { activationPending = false; activationTask = nil }
            }
            do {
                try Task.checkCancellation()
                if let activation { try await activation(item) }
                else { try await activateWorkspaceItem(item) }
                try Task.checkCancellation()
                guard isPresented, activationGeneration == generation else { return }
                dismiss?()
                await Metrics.shared.record("activation_total", milliseconds: activationTimer.milliseconds)
            } catch is CancellationError {
                // Closing the panel abandons this operation; it must not recover focus.
            } catch {
                guard !Task.isCancelled, isPresented, activationGeneration == generation else { return }
                notice = (error as? LocalizedError)?.errorDescription ?? "The selected item is unavailable."
                recoverFocus?(); refresh()
            }
        }
    }
    private func activateWorkspaceItem(_ item: WorkspaceItem) async throws {
        switch item.target {
        case .accessibility: try await windows.activate(item.target)
        case .chrome: try await chrome.activate(item.target)
        case .browserBridge:
            let application = try BrowserApplication(bundleID: item.bundleID)
            try await bridge.activate(item.target)
            try Task.checkCancellation()
            let focusTimer = LatencyTimer()
            prepareBrowserHandoff?()
            try await application.bringForward()
            await Metrics.shared.record("browser_native_focus", milliseconds: focusTimer.milliseconds)
        case .unavailable: throw AXIsProcessTrusted() ? NavigationError.unsupported : NavigationError.permission
        }
    }
    func saveSettings() {
        UserDefaults.standard.set(semanticEnabled, forKey: "semanticEnabled")
        if !semanticEnabled { search.setQuery(search.query) }
        UserDefaults.standard.set(pageContextEnabled, forKey: "pageContextEnabled")
        search.setUsePageContext(pageContextEnabled)
        UserDefaults.standard.set(chromeEnabled, forKey: "chromeEnabled")
        UserDefaults.standard.set(previewEnabled, forKey: "previewEnabled")
        UserDefaults.standard.set(shortcutIndex, forKey: "shortcutIndex")
        settingsRevision += 1; configureSemantic(); refine(); shortcutChanged?(); refresh()
    }
    func configureSemantic() {
        if let key = try? CredentialFile.read(path: keyPath) { engine = SemanticEngine(transport: LiveDecisionTransport(key: key)) }
        else { engine = nil }
    }
    func chooseKeyFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.message = "Choose a private .env file containing OPENAI_API_KEY. Moonshine reads it locally."
        if panel.runModal() == .OK, let url = panel.url {
            do { _ = try CredentialFile.read(path: url.path); UserDefaults.standard.set(url.path, forKey: "keyPath"); saveSettings() }
            catch { notice = (error as? LocalizedError)?.errorDescription ?? "Unable to read key file." }
        }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func requestCapture() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    static let fixtures: [WorkspaceItem] = [
        WorkspaceItem(id: "fixture-code", kind: .window, app: "Xcode", title: "Moonshine — WindowInventory.swift", context: "Synthetic window", aspectRatio: 1.6, screenFrame: .init(x: 60, y: 90, width: 1120, height: 700)),
        WorkspaceItem(id: "fixture-music", kind: .window, app: "Logic Pro", title: "Nocturne · late-night loop", context: "Synthetic window", aspectRatio: 1.85, screenFrame: .init(x: 520, y: 330, width: 1110, height: 600)),
        WorkspaceItem(id: "fixture-notes", kind: .window, app: "Notes", title: "Website redesign — typography, navigation, and an unusually long set of notes that should remain readable", context: "Synthetic window", aspectRatio: 0.85, screenFrame: .init(x: 1330, y: 150, width: 510, height: 600)),
        WorkspaceItem(id: "fixture-tab1", kind: .browserTab, app: "Safari", title: "Envelope generator — attack, decay, sustain, release", url: "https://example.org/music/envelopes", context: "Synthetic · Window 1"),
        WorkspaceItem(id: "fixture-tab2", kind: .browserTab, app: "Chrome", title: "Documentation", url: "https://example.com/swift", context: "Synthetic · Window 2"),
        WorkspaceItem(id: "fixture-tab3", kind: .browserTab, app: "Safari", title: "Documentation", url: "https://example.org/audio", context: "Synthetic · Window 3"),
        WorkspaceItem(id: "fixture-tab4", kind: .browserTab, app: "Chrome", title: "Chordbook — harmony sketches", url: "https://example.com/chordbook", context: "Synthetic · Window 2")
    ]
}
