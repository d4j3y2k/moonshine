import Foundation

/// Opt-in page labels. No body text, form values, or screenshots.
public struct PageContext: Hashable, Codable, Sendable {
    public var sourceURL: String
    public var capturedAt: Double
    public var siteName: String
    public var summary: String
    public var headings: [String]
    public var controls: [String]
    public init(sourceURL: String, capturedAt: Double = Date().timeIntervalSince1970,
                siteName: String = "", summary: String = "", headings: [String] = [], controls: [String] = []) {
        self.sourceURL = sourceURL; self.capturedAt = capturedAt; self.siteName = siteName
        self.summary = summary; self.headings = headings; self.controls = controls
    }
    public func validated(for url: String?, now: Double = Date().timeIntervalSince1970) -> PageContext? {
        guard let url, url == sourceURL, let parts = URLComponents(string: url),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, capturedAt.isFinite,
              now - capturedAt >= -5, now - capturedAt <= 120 else { return nil }
        let value = PageContext(sourceURL: sourceURL, capturedAt: capturedAt,
            siteName: Self.clean(siteName, 80), summary: Self.clean(summary, 400),
            headings: Self.cleanList(headings, count: 6, length: 80),
            controls: Self.cleanList(controls, count: 10, length: 40))
        return value.text.isEmpty ? nil : value
    }
    public var text: String { ([siteName, summary] + headings + controls).filter { !$0.isEmpty }.joined(separator: "\n") }
    /// Capture time and the full source URL stay local. Unchanged text keeps its evidence identity.
    public var evidence: PageEvidence { .init(siteName: siteName, summary: summary, headings: headings, controls: controls) }
    private static func clean(_ value: String, _ length: Int) -> String {
        String(value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(length))
    }
    private static func cleanList(_ values: [String], count: Int, length: Int) -> [String] {
        var seen = Set<String>()
        return values.prefix(100).map { clean($0, length) }.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(count).map { $0 }
    }
}

public struct PageEvidence: Hashable, Codable, Sendable {
    public let siteName: String
    public let summary: String
    public let headings: [String]
    public let controls: [String]
}
