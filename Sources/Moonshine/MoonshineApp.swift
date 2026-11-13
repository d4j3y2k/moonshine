import AppKit
import MoonshineCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var panel: PanelController!
    var statusItem: NSStatusItem!
    let hotKey = HotKey()
    private var pendingSearch: SearchHandoff?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(); panel = PanelController(model: model)
        installMainMenu()
        if model.demo && CommandLine.arguments.contains("--motion-check") {
            Task { @MainActor in
                do { try await runMotionChecks(panel: panel, model: model) }
                catch { print("Motion check failed: \(error.localizedDescription)"); exit(1) }
                NSApp.terminate(nil)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.indices.contains(index + 1), model.demo {
            let path = CommandLine.arguments[index + 1]
            panel.present(focus: false)
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    print("Native background render checks; keyboard focus verified separately")
                    guard model.search.items.count == 7 else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("overview-fixtures.png"))
                    // The first frame of the opening zoom: windows at their real positions, no chrome.
                    model.spread = false
                    try await Task.sleep(for: .milliseconds(80))
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("zoom-start-fixtures.png"))
                    model.spread = true
                    try await Task.sleep(for: .milliseconds(80))
                    // Pointer movement during fixture rendering can make an explicit
                    // selection. Start this keyboard-only check from a fresh search.
                    model.search.begin()
                    model.queryChanged("documentation"); model.cycle(backwards: false)
                    guard model.search.selectedID == "fixture-tab3" else { throw CocoaError(.validationMissingMandatoryProperty) }
                    let selected = model.search.selectedID
                    let ticket = model.search.ticket
                    model.search.apply(["fixture-tab2": 0, "fixture-code": 1], ticket: ticket)
                    guard model.search.selectedID == selected else { throw CocoaError(.validationMissingMandatoryProperty) }
                    print("Native keyboard selection with async refinement: PASS")
                    try await Task.sleep(for: .milliseconds(150))
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("search-fixtures.png"))
                    model.queryChanged("")
                    guard !model.search.isSearching && model.search.items.count == 7 else { throw CocoaError(.validationMissingMandatoryProperty) }
                    panel.dismiss(restore: true)
                    guard !panel.panel.isVisible else { throw CocoaError(.validationMissingMandatoryProperty) }
                    print("Clear query and dismiss: PASS")
                    var enriched = AppModel.fixtures
                    enriched[6].pageContext = PageContext(sourceURL: enriched[6].url!, summary: "An interactive piano for composing melodies and chords.", headings: ["Piano keyboard"], controls: ["Play", "Record"])
                    model.search.update(enriched); model.pageContextEnabled = true; model.search.setUsePageContext(true)
                    panel.present(focus: false); model.queryChanged("piano")
                    guard model.mainItems.map(\.id) == ["fixture-tab4"] else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try await Task.sleep(for: .milliseconds(150))
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("page-context-fixtures.png"))
                    model.pageContextEnabled = false; model.search.setUsePageContext(false); model.search.update(AppModel.fixtures); model.queryChanged("")
                    panel.dismiss(restore: true)
                    print("Page context recovers an opaque tab title: PASS")
                    let more = (0..<28).map { index -> WorkspaceItem in
                        var item = AppModel.fixtures[index % 3]
                        item.id = "dense-fixture-\(index)"; item.title = "Synthetic window \(index + 1) · \(item.title)"
                        return item
                    }
                    let moreTabs = (0..<60).map { index -> WorkspaceItem in
                        var item = AppModel.fixtures[3 + index % 4]
                        item.id = "dense-tab-\(index)"
                        item.context = "Synthetic · Window \(index / 10 + 1)"
                        if index == 59 { item.title = "A uniquely findable tab at the very end of a large inventory" }
                        return item
                    }
                    model.search.update(AppModel.fixtures + more + moreTabs); model.previews = FixturePreviews.make(for: model.search.items); panel.present(focus: false)
                    guard model.mainItems.count == 31, model.shelfItems.count == 64 else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try await Task.sleep(for: .milliseconds(200))
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("dense-fixtures.png"))
                    model.queryChanged("uniquely findable")
                    guard model.mainItems.count == 1, model.shelfItems.isEmpty, model.search.selectedID == "dense-tab-59" else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try await Task.sleep(for: .milliseconds(200))
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("dense-search-fixtures.png"))
                    model.move(keyCode: 126)
                    guard model.search.selectedID == "dense-tab-59" else { throw CocoaError(.validationMissingMandatoryProperty) }
                    model.queryChanged("documentation")
                    guard model.search.selectedID == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
                    model.cycle(backwards: false)
                    guard model.search.selectedID == "fixture-tab2" else { throw CocoaError(.validationMissingMandatoryProperty) }
                    print("Dense overview filters 95 items to one; arrows stay within plausible results: PASS")
                    model.search.update(model.search.items.filter { $0.id != "fixture-tab2" })
                    guard model.search.selected == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try await Task.sleep(for: .milliseconds(150))
                    try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("closed-selection-fixtures.png"))
                    print("Closed explicit target leaves selection empty: PASS")
                    if CommandLine.arguments.contains("--live-decisions") {
                        model.liveDemoEnabled = true
                        model.search.update(AppModel.fixtures); model.showTabs(false)
                        model.queryChanged("music production")
                        for _ in 0..<80 where model.isRefining { try await Task.sleep(for: .milliseconds(250)) }
                        guard model.refinementMilliseconds != nil, !model.mainItems.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
                        try panel.render(to: URL(fileURLWithPath: path).appendingPathComponent("live-decision-fixtures.png"))
                        print("Live Decisions filtered synthetic UI candidates: PASS (\(model.mainItems.count) matches)")
                    }
                    panel.dismiss(restore: true)
                    try await runSearchHandoffChecks(panel: panel, model: model)
                    print(await Metrics.shared.report())
                } catch { print("Native UI test failed: \(error.localizedDescription)"); exit(1) }
                NSApp.terminate(nil)
            }
            return
        }
        hotKey.onPress = { [weak self] in self?.panel.toggle() }
        model.shortcutChanged = { [weak self] in self?.registerShortcut() }
        registerShortcut()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Moonshine")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Moonshine", action: #selector(showOverview), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Moonshine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if let request = pendingSearch {
            pendingSearch = nil; panel.receiveSearch(request)
        } else if !CommandLine.arguments.contains("--background-launch") && (firstLaunch || CommandLine.arguments.contains("--show") || model.demo) { panel.present() }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let request = urls.compactMap({ SearchHandoff(url: $0, app: .moonshine) }).last else { return }
        if let panel { panel.receiveSearch(request) } else { pendingSearch = request }
    }
    func registerShortcut() { do { try hotKey.register(index: model.shortcutIndex) } catch { model.notice = error.localizedDescription } }
    private func installMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(); main.addItem(applicationItem)
        let application = NSMenu(title: "Moonshine"); applicationItem.submenu = application
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; application.addItem(settings); application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Quit Moonshine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"); edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        NSApp.mainMenu = main
    }
    @objc func showOverview() { panel.present() }
    @objc func showSettings() { panel.settings() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panel.present(); return true }
}

@main struct MoonshineApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        // Inspection mode gives UI automation a regular Dock application to attach to.
        application.setActivationPolicy(CommandLine.arguments.contains("--inspect") ? .regular : .accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
