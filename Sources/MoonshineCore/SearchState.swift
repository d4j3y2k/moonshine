import Foundation

public struct SearchTicket: Equatable, Sendable {
    public let generation: UInt64
    public let query: String
    public let evidence: [Evidence]
}

/// Identity selection is independent from relevance scores. `items` keeps a stable order while
/// someone is searching or has chosen something; results are ranked by local match quality only.
public struct SearchState: Sendable {
    public private(set) var items: [WorkspaceItem] = []
    public private(set) var query = ""
    public private(set) var generation: UInt64 = 0
    public private(set) var selectedID: String?
    public private(set) var explicitSelection = false
    public private(set) var semantic: [String: Double] = [:]
    private var scores: [String: Double] = [:]
    private var localScores: [String: Double] = [:]
    private var localScoresDirty = true
    private var preparedQuery = LocalMatch.Query("")
    private struct PreparedItem: Sendable {
        let item: WorkspaceItem
        let evidence: Evidence
        let document: LocalMatch.Document
    }
    private var prepared: [String: PreparedItem] = [:]
    private var ranked: [WorkspaceItem] = []
    private var lastEvidence: [Evidence] = []
    private var provisionalUntil: [String: Date] = [:]
    public private(set) var usePageContext = false
    public init() {}
    private var evidence: [Evidence] {
        guard usePageContext else { return lastEvidence }
        // Revalidate time-sensitive labels even without an inventory event. A response
        // arriving after expiry must never apply an old page-context ticket.
        return items.compactMap { item in
            guard let base = prepared[item.id]?.evidence else { return nil }
            let page = item.kind == .browserTab ? item.pageContext?.validated(for: item.url)?.evidence : nil
            return Evidence(id: base.id, kind: base.kind, app: base.app, title: base.title,
                            url: base.url, sourceRevision: base.sourceRevision, page: page)
        }
    }
    private mutating func prepareItems() {
        var next: [String: PreparedItem] = [:]
        next.reserveCapacity(items.count)
        for item in items {
            let page = usePageContext && item.kind == .browserTab ? item.pageContext?.validated(for: item.url)?.evidence : nil
            if let old = prepared[item.id], old.item.app == item.app, old.item.title == item.title,
               old.item.url == item.url, old.item.kind == item.kind, old.evidence.page == page {
                next[item.id] = old
            } else {
                let base = item.evidence
                let evidence = Evidence(id: base.id, kind: base.kind, app: base.app, title: base.title,
                                        url: base.url, sourceRevision: base.sourceRevision, page: page)
                next[item.id] = PreparedItem(item: item, evidence: evidence, document: LocalMatch.Document(item: item, page: page))
                localScoresDirty = true
            }
        }
        prepared = next
        lastEvidence = items.compactMap { prepared[$0.id]?.evidence }
    }
    public var ticket: SearchTicket { .init(generation: generation, query: query, evidence: evidence) }
    public mutating func setUsePageContext(_ enabled: Bool) {
        guard enabled != usePageContext else { return }
        usePageContext = enabled; generation &+= 1; semantic = [:]; provisionalUntil = [:]; prepareItems(); chooseDefault()
    }
    public var selected: WorkspaceItem? { items.first { $0.id == selectedID } }
    public var isSearching: Bool { !preparedQuery.text.isEmpty }
    /// Best local matches first. Items admitted only by refinement follow in their existing order:
    /// a predicate probability is a judgment, not a ranking, and late answers must not reshuffle.
    public var plausibleItems: [WorkspaceItem] { isSearching ? ranked : items }
    public var selectionWasFiltered: Bool { explicitSelection && selectedID == nil && isSearching }
    public mutating func begin(query: String = "") {
        explicitSelection = false; selectedID = nil; setQuery(query)
    }
    @discardableResult public mutating func update(_ incoming: [WorkspaceItem]) -> Bool {
        if incoming == items && !usePageContext && provisionalUntil.isEmpty { return false }
        for id in provisionalUntil.filter({ $0.value <= Date() }).map(\.key) {
            semantic.removeValue(forKey: id); provisionalUntil.removeValue(forKey: id)
        }
        let oldEvidence = lastEvidence
        var byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let retained = items.compactMap { byID.removeValue(forKey: $0.id) }
        let known = Set(retained.map(\.id))
        var seen = known
        if isSearching || explicitSelection {
            items = retained + incoming.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
        } else {
            // Nothing typed or chosen yet: follow the inventory's order, which is most recent first.
            var fresh = Set<String>()
            items = incoming.filter { fresh.insert($0.id).inserted }
        }
        if let selectedID, !items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        prepareItems()
        let changed = lastEvidence != oldEvidence
        if changed {
            generation &+= 1
            // Invalidate changed candidates, not unrelated selections. Page context refreshes
            // frequently; a changed tab must not withdraw another tab's valid judgment.
            let prior = Dictionary(uniqueKeysWithValues: oldEvidence.map { ($0.id, $0) })
            let unchanged = Set(lastEvidence.filter { prior[$0.id] == $0 }.map(\.id))
            // While fresh page labels are judged, retain the previous match briefly if
            // the actual page/title/app is unchanged. URL changes, expiry and revocation
            // never qualify. A fresh answer or failure ends this provisional state.
            let labelUpdates = Set(lastEvidence.filter {
                guard let old = prior[$0.id] else { return false }
                return old.sourceRevision == $0.sourceRevision && old.page != nil && $0.page != nil && old.page != $0.page
            }.map(\.id))
            let now = Date()
            for id in labelUpdates where semantic[id] != nil && provisionalUntil[id] == nil { provisionalUntil[id] = now.addingTimeInterval(3) }
            semantic = semantic.filter { unchanged.contains($0.key) || (labelUpdates.contains($0.key) && (provisionalUntil[$0.key] ?? .distantPast) > now) }
            provisionalUntil = provisionalUntil.filter { semantic[$0.key] != nil && $0.value > now }
        }
        chooseDefault()
        return changed
    }
    public mutating func setQuery(_ value: String) {
        query = String(value.prefix(400)); preparedQuery = LocalMatch.Query(query)
        localScoresDirty = true
        if usePageContext { prepareItems() }
        generation &+= 1; semantic = [:]; provisionalUntil = [:]; chooseDefault()
    }
    @discardableResult public mutating func apply(_ values: [String: Double], ticket: SearchTicket) -> Bool {
        guard ticket == self.ticket, values.keys.allSatisfy({ prepared[$0] != nil }),
              values.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        semantic.merge(values, uniquingKeysWith: { _, new in new })
        for id in values.keys { provisionalUntil.removeValue(forKey: id) }
        chooseDefault(); return true
    }
    public mutating func discardProvisionalJudgments() {
        guard !provisionalUntil.isEmpty else { return }
        for id in provisionalUntil.keys { semantic.removeValue(forKey: id) }
        provisionalUntil = [:]; chooseDefault()
    }
    public func score(_ item: WorkspaceItem) -> Double {
        guard isSearching else { return 1 }
        return scores[item.id] ?? max(LocalMatch.score(query: query, item: item, includePageContext: usePageContext), semantic[item.id] ?? 0)
    }
    public mutating func select(_ id: String) {
        guard plausibleItems.contains(where: { $0.id == id }) else { return }
        selectedID = id; explicitSelection = true
    }
    public mutating func restrictSelection(to ids: [String]) {
        if let id = selectedID, !ids.contains(id) { selectedID = nil }
        if !explicitSelection && selectedID == nil { selectedID = ids.first }
    }
    public mutating func move(_ offset: Int, among visibleIDs: [String]? = nil) {
        let plausible = Set(plausibleItems.map(\.id))
        let ids = (visibleIDs ?? items.map(\.id)).filter { plausible.contains($0) }
        guard !ids.isEmpty else { return }
        let current = selectedID.flatMap { ids.firstIndex(of: $0) }
        let index = current.map { min(max(0, $0 + offset), ids.count - 1) } ?? (offset < 0 ? ids.count - 1 : 0)
        select(ids[index])
    }
    private mutating func chooseDefault() {
        // Semantic batches and geometry refreshes reuse the local matches for this query.
        if localScoresDirty {
            localScores = isSearching ? prepared.mapValues { $0.document.score(preparedQuery) } : [:]
            localScoresDirty = false
        }
        scores = [:]; ranked = []
        var local: [(item: WorkspaceItem, score: Double, offset: Int)] = [], recovered: [WorkspaceItem] = []
        for (offset, item) in items.enumerated() {
            guard isSearching else { scores[item.id] = 1; continue }
            let value = localScores[item.id] ?? 0
            let judged = semantic[item.id] ?? 0
            scores[item.id] = max(value, judged)
            if value >= 0.4 { local.append((item, value, offset)) } else if judged >= 0.4 { recovered.append(item) }
        }
        ranked = local.sorted { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }.map(\.item) + recovered
        // Filtering can withdraw a selection, but must never silently retarget an explicit choice.
        if let id = selectedID, isSearching, let item = items.first(where: { $0.id == id }), score(item) < 0.4 { selectedID = nil }
        guard !explicitSelection else { return }
        // At rest, start on the window behind the one in front, so open + Return goes back.
        if !isSearching { selectedID = (items.first { $0.recency != 0 } ?? items.first)?.id; return }
        selectedID = ranked.first?.id
    }
}
