import AppKit
import MoonshineCore
import MoonshinePlatform

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
    for accepted in [true, false] {
        panel.receiveSearch(SearchHandoff(query: "outgoing"), focus: false)
        panel.switchSearch()
        let staleCompletion = completion
        panel.present(focus: false, searchQuery: "reopened")
        model.notice = nil
        staleCompletion?(accepted)
        try check(model.isPresented && model.search.query == "reopened" && model.notice == nil,
                  "late handoff completion cannot change an ordinary reopened panel")
        let before = requests.count
        panel.switchSearch()
        try check(requests.count == before + 1, "reopened panel can dispatch a new handoff")
        completion?(true)
    }
    panel.receiveSearch(SearchHandoff(query: ""), focus: false)
    try check(model.search.query.isEmpty, "empty search replaces stale text")
    for succeeds in [true, false] {
        var replies: [CheckedContinuation<Void, Error>] = []
        let activationModel = AppModel(activation: { _ in
            try await withCheckedThrowingContinuation { replies.append($0) }
        })
        try check(activationModel.pairingCode != model.pairingCode, "demo models use independent ephemeral pairing identities")
        let activationPanel = PanelController(model: activationModel)
        var dismissals = 0, recoveries = 0
        activationModel.dismiss = { dismissals += 1 }
        activationModel.recoverFocus = { recoveries += 1 }
        activationPanel.present(focus: false); activationModel.activate("fixture-code")
        for _ in 0..<100 where replies.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try check(replies.count == 1, "activation fixture starts")
        let oldReply = replies.removeFirst()
        // Exercise both ordinary close/reopen and a direct incoming handoff while
        // the original activation is still pending in this same presentation.
        if succeeds { activationPanel.dismiss(restore: false) }
        activationPanel.receiveSearch(SearchHandoff(query: "Nocturne"), focus: false)
        activationModel.activate("fixture-music")
        for _ in 0..<100 where replies.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try check(replies.count == 1, "reopened search can activate without waiting for the obsolete operation")
        if succeeds { oldReply.resume() } else { oldReply.resume(throwing: NavigationError.missing) }
        try await Task.sleep(for: .milliseconds(20))
        try check(activationModel.activationPending && activationModel.search.query == "Nocturne" &&
                  activationModel.notice == nil && dismissals == 0 && recoveries == 0,
                  "obsolete activation cannot dismiss, recover focus, or clear a newer activation")
        replies.removeFirst().resume()
        for _ in 0..<100 where activationModel.activationPending { try await Task.sleep(for: .milliseconds(2)) }
        try check(dismissals == 1 && !activationModel.activationPending, "current activation still completes normally")
        activationPanel.dismiss(restore: false)
    }
    print("Activation isolation: cancelled success/failure cannot affect a newer search PASS")
    print("Motion isolation: stable targets, latest snapshot, immediate typing, and dismissal PASS")
    print("Search handoff: query, caret, composition, repeat, failure, round-trip race, and empty query PASS")
}
