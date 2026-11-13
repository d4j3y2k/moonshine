import AppKit
import MoonshineCore
import MoonshinePlatform

@main struct MoonshineCheck {
    static func main() async {
        let args = CommandLine.arguments
        do {
            if args.contains("--live-latency") {
                let key = try CredentialFile.read(path: FileManager.default.currentDirectoryPath + "/.env.local")
                let reusable = LiveDecisionTransport(key: key)
                let items = (0..<70).map { index in
                    WorkspaceItem(id: "synthetic-\(index)", kind: .browserTab, app: index % 2 == 0 ? "Safari" : "Chrome",
                                  title: index % 3 == 0 ? "Piano composition exercise \(index)" : "Software documentation \(index)",
                                  url: "https://example.org/\(index)")
                }
                let batch = DecisionBatch(query: "practice an instrument", evidence: items.map(\.evidence))
                let body = try batch.body()
                print("Transport comparison: six requests, 70 synthetic candidates each; identical payload, alternating session strategy.")
                for reuse in [false, true, true, false, false, true] {
                    let transport = reuse ? reusable : LiveDecisionTransport(key: key)
                    let timer = LatencyTimer()
                    let answers = try batch.decode(await transport.send(body: body))
                    await Metrics.shared.record(reuse ? "transport_reused_session" : "transport_fresh_session", milliseconds: timer.milliseconds)
                    guard answers.count == items.count else { throw SemanticError.invalidResponse }
                }
                print(await Metrics.shared.report())
            } else if args.contains("--live-context-smoke") {
                let key = try CredentialFile.read(path: FileManager.default.currentDirectoryPath + "/.env.local")
                let engine = SemanticEngine(transport: LiveDecisionTransport(key: key))
                let url = "https://example.org/keypad"
                let enriched = WorkspaceItem(id: "synthetic-keypad", kind: .browserTab, app: "Chrome", title: "Keypad", url: url,
                    pageContext: PageContext(sourceURL: url, summary: "Interactive piano keyboard for composing melodies and chords.", headings: ["Piano keyboard", "Chord progression"], controls: ["Play", "Record", "Transpose", "Tempo"]))
                let unrelated = WorkspaceItem(id: "synthetic-settings", kind: .browserTab, app: "Safari", title: "Account settings", url: "https://example.org/settings")
                let query = "practice an instrument"
                let before = try await engine.evaluate(DecisionBatch(query: query, evidence: [enriched.evidence, unrelated.evidence]))
                let after = try await engine.evaluate(DecisionBatch(query: query, evidence: [enriched.evidence(includePageContext: true), unrelated.evidence]))
                print("Live context comparison · synthetic pages only · same query and titles")
                print(String(format: "Synthetic Keypad relevance: metadata %.3f; page context %.3f", before[enriched.id] ?? 0, after[enriched.id] ?? 0))
                print(String(format: "Unrelated synthetic settings relevance with context: %.3f", after[unrelated.id] ?? 0))
                print(await Metrics.shared.report())
            } else if args.contains("--live-smoke") {
                let key = try CredentialFile.read(path: FileManager.default.currentDirectoryPath + "/.env.local")
                let engine = SemanticEngine(transport: LiveDecisionTransport(key: key))
                let items = [
                    WorkspaceItem(id: "synthetic-audio", kind: .browserTab, app: "Safari", title: "ADSR envelope reference", url: "https://example.org/audio/envelopes"),
                    WorkspaceItem(id: "synthetic-code", kind: .window, app: "Xcode", title: "Moonshine — SearchState.swift")
                ]
                let result = try await engine.evaluate(DecisionBatch(query: "the page about synth envelopes", evidence: items.map(\.evidence)))
                print("Live Decisions protocol smoke test · synthetic metadata · \(result.count) validated answers")
                print("Intended synthetic target ranked first: \((result[items[0].id] ?? 0) > (result[items[1].id] ?? 0))")
                print(await Metrics.shared.report())
            } else if args.contains("--live-workspace-eval") {
                let inventory = WindowInventory()
                let allowedApps = Set(["com.apple.finder", "com.apple.TextEdit", "com.apple.Terminal", "com.mitchellh.ghostty", "ai.storyteller.vectorcraft"])
                let items = await inventory.discover(apps: RunningApp.snapshot().filter { allowedApps.contains($0.bundleID) })
                var cases: [Evaluation.Case] = []
                for (app, query) in [("ai.storyteller.vectorcraft", "the vector illustration app"),
                                     ("com.apple.finder", "browse my files"),
                                     ("com.apple.TextEdit", "my text document"),
                                     ("com.apple.Terminal", "a terminal shell") ] {
                    let ids = items.filter { $0.bundleID == app }.map(\.id)
                    if !ids.isEmpty { cases.append(.init(query: query, intendedIDs: ids)) }
                }
                let terminals = items.filter { ["com.apple.Terminal", "com.mitchellh.ghostty"].contains($0.bundleID) }.map(\.id)
                if !terminals.isEmpty { cases.append(.init(query: "a command line session", intendedIDs: terminals)) }
                if let first = items.first { cases.append(.init(query: first.title, intendedIDs: items.filter { $0.title == first.title }.map(\.id))) }
                cases.append(.init(query: "a live Mars rover telemetry console", intendedIDs: []))
                guard !items.isEmpty else { throw NavigationError.missing }
                print("Real inventory evaluation: \(items.count) windows. App-based intended targets were defined by the test author; this is not a user study.")
                try await evaluate(fixture: Evaluation(provenance: "real", items: items, cases: cases))
            } else if let index = args.firstIndex(of: "--evaluate"), args.indices.contains(index + 1) {
                try await evaluate(path: args[index + 1])
            } else {
                let apps = RunningApp.snapshot()
                let inventory = WindowInventory()
                let started = Date()
                let items = await inventory.discover(apps: apps)
                print("Accessibility granted: \(AXIsProcessTrusted())")
                print("Screen Recording granted: \(CGPreflightScreenCaptureAccess())")
                print("Regular applications: \(apps.count); non-browser windows: \(items.count)")
                print("Exact activation targets: \(items.filter { $0.target != .unavailable }.count)")
                print(String(format: "Discovery: %.1f ms", Date().timeIntervalSince(started) * 1000))
                if args.contains("--previews") {
                    let previewStart = Date()
                    let previews = await inventory.previews(items: items)
                    print("Local cached previews: \(previews.count)")
                    print(String(format: "Preview batch: %.1f ms", Date().timeIntervalSince(previewStart) * 1000))
                }
                if args.contains("--chrome"), let chrome = apps.first(where: { $0.bundleID == "com.google.Chrome" }) {
                    let tabs = try await ChromeAdapter().discover(app: chrome)
                    print("Chrome regular tabs: \(tabs.count)")
                }
            }
        } catch {
            // Never print HTTP bodies, credentials, browsing metadata, or underlying filesystem errors.
            print("Check failed: \((error as? SemanticError)?.errorDescription ?? (error as? NavigationError)?.errorDescription ?? "Unable to complete the requested check")")
            exit(1)
        }
    }
    struct Evaluation: Decodable {
        let provenance: String
        let items: [WorkspaceItem]
        let cases: [Case]
        struct Case: Decodable { let query: String; let intendedIDs: [String] }
    }
    static func evaluate(path: String) async throws {
        let fixture = try JSONDecoder().decode(Evaluation.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try await evaluate(fixture: fixture)
    }
    static func evaluate(fixture: Evaluation) async throws {
        guard fixture.items.count <= DecisionBatch.limit, fixture.cases.count <= 30,
              Set(fixture.items.map(\.id)).count == fixture.items.count else { throw SemanticError.oversized }
        let key = try CredentialFile.read(path: FileManager.default.currentDirectoryPath + "/.env.local")
        let engine = SemanticEngine(transport: LiveDecisionTransport(key: key))
        var localHits = 0, semanticHits = 0, noMatchPasses = 0, noMatchCount = 0
        for (index, example) in fixture.cases.enumerated() {
            let known = Set(fixture.items.map(\.id)); guard Set(example.intendedIDs).isSubset(of: known) else { throw SemanticError.invalidResponse }
            var state = SearchState(); state.update(fixture.items); state.setQuery(example.query)
            if let selected = state.selectedID, example.intendedIDs.contains(selected) { localHits += 1 }
            let result = try await engine.evaluate(DecisionBatch(query: example.query, evidence: fixture.items.map(\.evidence)))
            state.apply(result, ticket: state.ticket)
            if let selected = state.selectedID, example.intendedIDs.contains(selected) { semanticHits += 1 }
            if example.intendedIDs.isEmpty { noMatchCount += 1; if state.selectedID == nil { noMatchPasses += 1 } }
            print("Case \(index + 1): all intended candidates remain reachable: \(Set(example.intendedIDs).isSubset(of: Set(state.items.map(\.id))))")
        }
        print("Evaluation provenance: \(fixture.provenance == "real" ? "real locally labeled inventory" : "synthetic fixtures")")
        print("Queries: \(fixture.cases.count); local intended default: \(localHits); assisted intended default: \(semanticHits); no-match: \(noMatchPasses)/\(noMatchCount)")
        print(await Metrics.shared.report())
    }
}
