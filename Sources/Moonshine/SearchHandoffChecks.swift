import AppKit
import MoonshineCore

/// Hidden native-panel checks with an injected companion; no external app is launched.
@MainActor func runSearchHandoffChecks(panel: PanelController, model: AppModel) async throws {
    func check(_ condition: Bool, _ label: String) throws {
        guard condition else { print("FAIL: \(label)"); throw CocoaError(.validationMissingMandatoryProperty) }
    }
    func event(_ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: repeated, keyCode: 48)!
    }
    panel.present(focus: false)
    model.isClosing = true
    panel.toggle(focus: false)
    try check(model.isPresented && !model.isClosing, "shortcut interrupts closing instead of waiting for the animation")
    panel.dismiss(restore: false)
    let savedItems = model.search.items, savedPreviews = model.previews
    panel.present(focus: false)
    model.isSettling = true; model.spread = false
    var earlier = AppModel.fixtures[3], latest = AppModel.fixtures[4]
    earlier.id = "motion-earlier"; latest.id = "motion-latest"
    model.mergeInventory([earlier]); model.mergeInventory([latest])
    try check(model.search.items == savedItems, "inventory does not move targets during exposure")
    model.queryChanged("documentation")
    try check(!model.isSettling && model.spread && model.search.items == [latest], "typing immediately settles motion and adopts only the latest inventory")
    try check(model.search.selectedID == latest.id, "typing during exposure filters immediately")
    model.isSettling = true
    panel.dismiss(restore: false)
    try check(!model.isSettling && !model.isPresented, "hidden dismissal clears transition state")
    model.search.update(savedItems); model.previews = savedPreviews
    let original = panel.dispatchSearch
    defer { panel.dispatchSearch = original; panel.dismiss(restore: false) }
    var requests: [SearchHandoff] = []
    var completion: ((Bool) -> Void)?
    panel.dispatchSearch = { request, callback in requests.append(request); completion = callback }
    let query = "  piano & café 🎹 "
    panel.receiveSearch(SearchHandoff(query: query), focus: false)
    try await Task.sleep(for: .milliseconds(100))
    try check(model.search.query == query && panel.keyboardReady, "handoff focuses the exact incoming query")
    panel.present(focus: false)
    let editor = panel.panel.firstResponder as? NSTextView
    try check(editor?.selectedRange() == NSRange(location: (query as NSString).length, length: 0), "handoff leaves the caret at the end")
    try check(panel.handleKeyDown(event(.control)) != nil && requests.isEmpty, "modified Tab remains native")
    _ = panel.handleKeyDown(event(repeated: true))
    try check(requests.isEmpty, "held Tab cannot bounce between apps")
    editor?.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try check(panel.handleKeyDown(event()) != nil && requests.isEmpty, "Tab preserves input-method composition")
    editor?.unmarkText()
    panel.receiveSearch(SearchHandoff(query: query), focus: false)
    _ = panel.handleKeyDown(event())
    try check(requests.last?.query == query && !panel.panel.isVisible, "Tab sends the query and releases the source panel")
    completion?(false)
    try check(model.isPresented && model.search.query == query && model.notice != nil, "failed handoff retains the query")
    _ = panel.handleKeyDown(event(.shift))
    let oldCompletion = completion
    panel.receiveSearch(SearchHandoff(query: "new query"), focus: false)
    oldCompletion?(true)
    try check(model.isPresented && model.search.query == "new query", "late callback cannot close a newer incoming search")
    _ = panel.handleKeyDown(event())
    completion?(true)
    try check(!model.isPresented && !panel.panel.isVisible && !model.isClosing, "accepted handoff closes without starting a zoom-out")
    panel.receiveSearch(SearchHandoff(query: ""), focus: false)
    try check(model.search.query.isEmpty, "empty search replaces stale text")
    print("Motion isolation: stable targets, latest snapshot, immediate typing, and dismissal PASS")
    print("Search handoff: query, caret, composition, repeat, failure, round-trip race, and empty query PASS")
}
