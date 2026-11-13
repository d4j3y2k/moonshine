import Foundation

// Synthetic metadata only. Compile with the Core sources and -O, outside XCTest.
@main enum LatencyBenchmark {
    static func main() {
        let context = CommandLine.arguments.contains("--page-context")
        print("page_context=\(context)")
        for count in [96, 512, 2000] {
            let items = (0..<count).map { index in
                WorkspaceItem(id: "synthetic-\(index)", kind: index % 3 == 0 ? .window : .browserTab,
                    app: index % 3 == 0 ? "Visual Studio Code" : "Safari",
                    title: "Workspace \(index) — Moonshine music editor and project notes",
                    url: "https://example.org/projects/\(index)?local=1", context: "Window \(index % 12)",
                    pageContext: context ? PageContext(sourceURL: "https://example.org/projects/\(index)?local=1",
                        summary: "A small piano editor with an interactive keyboard for composing music.",
                        headings: ["Project notes", "Piano keyboard"], controls: ["Play", "Record", "Tempo"]) : nil)
            }
            var state = SearchState(); state.setUsePageContext(context); state.update(items)
            let queries = ["moon", "music", "workspce", "visual", "unmatched", "project notes"]
            var measurements: [String: [Double]] = [:]
            var checksum = 0
            func measure(_ name: String, _ body: () -> Void) {
                let start = ProcessInfo.processInfo.systemUptime; body()
                measurements[name, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            for iteration in 0..<30 {
                measure("typing") { state.setQuery(queries[iteration % queries.count]); checksum += state.plausibleItems.count }
                measure("unchanged_inventory") { _ = state.update(items) }
                measure("ticket") { checksum += state.ticket.evidence.count }
                let ticket = state.ticket
                measure("semantic_apply") { _ = state.apply([items[0].id: 0.7], ticket: ticket) }
            }
            for name in measurements.keys.sorted() {
                let values = measurements[name]!.sorted()
                print(String(format: "items=%d %@ n=%d p50=%.3fms p95=%.3fms", count, name, values.count, values[14], values[28]))
            }
            print("checksum=\(checksum)")
        }
    }
}
