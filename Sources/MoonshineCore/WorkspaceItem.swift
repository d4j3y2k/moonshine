import Foundation
import CryptoKit

public enum ItemKind: String, Codable, Sendable { case window, browserTab }

/// Targets are produced only by local adapters. They never appear in model output.
public enum ActivationTarget: Hashable, Codable, Sendable {
    case accessibility(pid: Int32, launch: Double, token: String)
    case chrome(pid: Int32, launch: Double, tabID: Int)
    case browserBridge(client: String, session: String, tabID: Int)
    case unavailable
}

/// Where a window sits on the displays, in global top-left points. Used only to animate the
/// overview from and back to the real layout; never evidence and never an activation target.
public struct ScreenFrame: Hashable, Codable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct WorkspaceItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: ItemKind
    public var app: String
    public var bundleID: String
    public var title: String
    public var url: String?
    public var context: String
    public var target: ActivationTarget
    /// Local display geometry only. It is excluded from semantic evidence and activation identity.
    public var aspectRatio: Double?
    public var pageContext: PageContext?
    /// Local front-to-back position among on-screen windows; 0 is the window in front when the
    /// inventory was read. Ordering only: excluded from semantic evidence and activation identity.
    public var recency: Int?
    /// Present only for windows currently visible on screen.
    public var screenFrame: ScreenFrame?
    public init(id: String, kind: ItemKind, app: String, bundleID: String = "", title: String,
                url: String? = nil, context: String = "", target: ActivationTarget = .unavailable, aspectRatio: Double? = nil, pageContext: PageContext? = nil, recency: Int? = nil, screenFrame: ScreenFrame? = nil) {
        self.id = id; self.kind = kind; self.app = app; self.bundleID = bundleID
        self.title = title; self.url = url; self.context = context; self.target = target
        self.aspectRatio = aspectRatio
        self.pageContext = pageContext
        self.recency = recency
        self.screenFrame = screenFrame
    }
    public var domain: String { url.flatMap { URL(string: $0)?.host } ?? "" }
    /// No credentials, query strings, fragments, screenshots, page text or browsing history.
    public var inferenceURL: String? {
        guard let url, var parts = URLComponents(string: url),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string.map { String($0.prefix(360)) }
    }
    public var evidence: Evidence { evidence(includePageContext: false) }
    public func evidence(includePageContext: Bool) -> Evidence {
        let page = includePageContext && kind == .browserTab ? pageContext?.validated(for: url)?.evidence : nil
        let revision = digest((try? JSONEncoder().encode([app, title, url ?? "", kind.rawValue])) ?? Data())
        return Evidence(id: id, kind: kind.rawValue, app: String(app.prefix(80)),
                 title: String(title.prefix(280)), url: inferenceURL, sourceRevision: revision, page: page)
    }
}

public struct Evidence: Hashable, Codable, Sendable {
    public let id: String
    public let kind: String
    public let app: String
    public let title: String
    public let url: String?
    /// Local-only digest includes the full URL/title, so unseen navigation invalidates old judgments.
    public let sourceRevision: String
    public let page: PageEvidence?
}

public func digest(_ data: Data) -> String {
    let hex = Array("0123456789abcdef".utf8)
    return String(decoding: SHA256.hash(data: data).flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }, as: UTF8.self)
}

public enum LocalMatch {
    public static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// Tiers, best first: exact title/app, title prefix, word start in title, anywhere in title,
    /// app prefix, anywhere in the evidence, every word present, initials, every word present
    /// allowing a typo. Anything below 0.4 stays hidden unless refinement recovers it.
    public static func score(query: String, item: WorkspaceItem, includePageContext: Bool = false) -> Double {
        Document(item: item, includePageContext: includePageContext).score(Query(query))
    }
    /// Prepared once per keystroke, shared by every candidate.
    struct Query: Sendable {
        let text: String
        let words: [String]
        let characters: [[Character]]
        init(_ value: String) {
            text = normalize(value)
            words = text.split(separator: " ").filter { $0.count > 1 }.map(String.init)
            characters = words.map(Array.init)
        }
    }
    /// Stable metadata is normalized when inventory changes, never again for each key.
    struct Document: Sendable {
        let title: String, app: String, haystack: String
        let named: [[Character]]
        let titleInitials: String, appInitials: String
        init(item: WorkspaceItem, includePageContext: Bool = false, page: PageEvidence? = nil) {
            title = normalize(item.title); app = normalize(item.app)
            let labels = page ?? (includePageContext && item.kind == .browserTab ? item.pageContext?.validated(for: item.url)?.evidence : nil)
            let text = labels.map { ([$0.siteName, $0.summary] + $0.headings + $0.controls).joined(separator: "\n") } ?? ""
            haystack = title + " " + app + " " + normalize(item.url ?? "") + " " + normalize(text)
            let titleTokens = tokens(title), appTokens = tokens(app)
            named = (titleTokens + appTokens).map(Array.init)
            titleInitials = String(titleTokens.compactMap(\.first)); appInitials = String(appTokens.compactMap(\.first))
        }
        func score(_ query: Query) -> Double {
            let q = query.text
            guard !q.isEmpty else { return 1 }
            if title == q || app == q { return 1 }
            if title.hasPrefix(q) { return 0.97 }
            if title.contains(q) { return startsWord(q, in: title) ? 0.96 : 0.95 }
            if app.hasPrefix(q) { return 0.9 }
            if haystack.contains(q) { return 0.85 }
            let words = query.words
            guard !words.isEmpty else { return 0 }
            let hits = words.filter { haystack.contains($0) }.count
            if hits == words.count { return 0.75 }
            if words.count == 1, !q.contains(" "), (2...6).contains(q.count),
               titleInitials.hasPrefix(q) || appInitials.hasPrefix(q) { return 0.6 }
            let forgiving = words.indices.allSatisfy { index in
                haystack.contains(words[index]) || named.contains { nearly(query.characters[index], $0) }
            }
            if forgiving { return 0.55 }
            return Double(hits) / Double(words.count) * 0.48
        }
    }
    static func tokens(_ value: String) -> [Substring] {
        value.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }
    static func startsWord(_ query: String, in text: String) -> Bool {
        var from = text.startIndex
        while let range = text.range(of: query, range: from..<text.endIndex) {
            if range.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber) { return true }
            from = text.index(after: range.lowerBound)
        }
        return false
    }
    /// One slip (two in long words) against a word or the part of it typed so far.
    /// Short words are excluded: a single edit turns too many of them into each other.
    static func nearly(_ word: [Character], _ token: [Character]) -> Bool {
        guard word.count >= 5, token.count + 1 >= word.count else { return false }
        let limit = word.count >= 9 ? 2 : 1
        if distance(word, token, limit: limit) <= limit { return true }
        return token.count > word.count && distance(word, Array(token.prefix(word.count)), limit: limit) <= limit
    }
    /// Edit distance counting an adjacent swap as one edit; gives up early past the limit.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var beforePrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count), current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var best = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, beforePrevious[j - 2] + 1) }
                current[j] = value; best = min(best, value)
            }
            if best > limit { return limit + 1 }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return previous[b.count]
    }
}
