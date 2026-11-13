import Foundation
import Network
import MoonshineCore

/// Paired, loopback-only transport for Safari's WebExtension and optional Chrome profiles.
/// The token authorizes metadata sync and exact-tab activation, never URLs or commands.
public actor BrowserBridge {
    public static let port: UInt16 = 49731
    private struct Tab: Decodable { let id: Int; let windowId: Int; let title: String; let url: String?; let incognito: Bool; let pageContext: PageContext? }
    private struct Sync: Decodable { let client: String; let session: String; let browser: String; let tabs: [Tab]; let acknowledgements: [Ack]?; let transportVersion: Int? }
    private struct Ack: Decodable { let id: String; let success: Bool }
    private struct Command: Encodable { let id: String; let session: String; let tabID: Int; let expiresAt: Double }
    private struct Client { var session: String; var updated: Date; var items: [WorkspaceItem] }
    private struct Pending { let client: String; let command: Command; let continuation: CheckedContinuation<Void, Error>; let timer: LatencyTimer; var delivered: LatencyTimer? }
    private var clients: [String: Client] = [:]
    private var pending: [String: Pending] = [:]
    private struct Poll { let id: UUID; let session: String; let continuation: CheckedContinuation<Void, Never> }
    private var polls: [String: Poll] = [:]
    private var updates: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var listener: NWListener?
    private let token: String
    public init(token: String) { self.token = token }
    public func inventoryUpdates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            updates[id] = continuation
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { updates.removeValue(forKey: id) }
    private func inventoryChanged() { for observer in updates.values { observer.yield(()) } }
    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        let token = self.token
        listener.newConnectionHandler = { [weak self] connection in
            let session = HTTPConnection(connection: connection, token: token) { [weak self] data in
                guard let self else { return Data("{}".utf8) }
                return await self.sync(data)
            }
            session.start()
        }
        listener.start(queue: DispatchQueue(label: "moonshine.browser.bridge"))
        self.listener = listener
    }
    public func inventory() -> [WorkspaceItem] {
        let expired = clients.filter { Date().timeIntervalSince($0.value.updated) > 12 }.map(\.key)
        for client in expired { clients.removeValue(forKey: client) }
        if !expired.isEmpty { inventoryChanged() }
        return clients.keys.sorted().flatMap { clients[$0]?.items ?? [] }
    }
    // Version 2 keeps one authenticated sync waiting for at most one second.
    // Activation wakes it immediately; the next sync carries the acknowledgement.
    // Legacy extensions retain their original array response and polling behavior.
    func sync(_ data: Data) async -> Data {
        guard let message = try? JSONDecoder().decode(Sync.self, from: data),
              UUID(uuidString: message.client) != nil, UUID(uuidString: message.session) != nil,
              ["Safari", "Chrome"].contains(message.browser), message.tabs.count <= 2000 else { return Data("{}".utf8) }
        let bundle = message.browser == "Safari" ? "com.apple.Safari" : "com.google.Chrome"
        var seen = Set<Int>()
        let items = message.tabs.filter { !$0.incognito && $0.id >= 0 && seen.insert($0.id).inserted }.map {
            WorkspaceItem(id: "bridge:\(message.client):\(message.session):\($0.id)", kind: .browserTab,
                app: message.browser, bundleID: bundle, title: String($0.title.prefix(1000)), url: $0.url.map { String($0.prefix(2048)) },
                context: "Window \($0.windowId) · Profile \(message.client.prefix(4))",
                target: .browserBridge(client: message.client, session: message.session, tabID: $0.id),
                pageContext: $0.pageContext?.validated(for: $0.url))
        }
        let changed = clients[message.client]?.items != items
        clients[message.client] = Client(session: message.session, updated: Date(), items: items)
        // A restarted worker/browser cannot complete commands from its old session.
        for (id, value) in pending where value.client == message.client && value.command.session != message.session {
            pending.removeValue(forKey: id)?.continuation.resume(throwing: NavigationError.missing)
        }
        if changed { inventoryChanged() }
        for ack in message.acknowledgements ?? [] {
            guard let p = pending[ack.id], p.client == message.client, p.command.session == message.session else { continue }
            pending.removeValue(forKey: ack.id)
            let total = p.timer.milliseconds, delivery = p.delivered?.milliseconds
            Task {
                await Metrics.shared.record("bridge_total", milliseconds: total)
                if let delivery { await Metrics.shared.record("bridge_delivery_to_ack", milliseconds: delivery) }
            }
            if ack.success { p.continuation.resume() } else { p.continuation.resume(throwing: NavigationError.missing) }
        }
        if message.transportVersion == 2 && !pending.values.contains(where: { $0.client == message.client && $0.command.session == message.session }) {
            let pollID = UUID()
            await withCheckedContinuation { continuation in
                polls.removeValue(forKey: message.client)?.continuation.resume()
                polls[message.client] = Poll(id: pollID, session: message.session, continuation: continuation)
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    self.finishPoll(client: message.client, id: pollID)
                }
            }
        }
        guard clients[message.client]?.session == message.session else { return reply([], version: message.transportVersion) }
        for (id, value) in pending where value.client == message.client && value.command.session == message.session && value.delivered == nil {
            pending[id]?.delivered = LatencyTimer()
            let elapsed = value.timer.milliseconds
            Task { await Metrics.shared.record("bridge_command_wait", milliseconds: elapsed) }
        }
        let commands = pending.values.filter { $0.client == message.client && $0.command.session == message.session }.map(\.command)
        return reply(commands, version: message.transportVersion)
    }
    private func reply(_ commands: [Command], version: Int?) -> Data {
        struct Reply: Encodable { let commands: [Command]; let transportVersion = 2 }
        return (try? version == 2 ? JSONEncoder().encode(Reply(commands: commands)) : JSONEncoder().encode(commands)) ?? Data("[]".utf8)
    }
    private func finishPoll(client: String, id: UUID) {
        guard polls[client]?.id == id else { return }
        polls.removeValue(forKey: client)?.continuation.resume()
    }
    public func activate(_ target: ActivationTarget) async throws {
        guard case let .browserBridge(client, session, tabID) = target,
              let source = clients[client], source.session == session,
              Date().timeIntervalSince(source.updated) < 12,
              source.items.contains(where: { $0.target == target }) else { throw NavigationError.missing }
        let id = UUID().uuidString
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(client: client, command: Command(id: id, session: session, tabID: tabID, expiresAt: Date().timeIntervalSince1970 * 1000 + 4500), continuation: continuation, timer: LatencyTimer())
            if polls[client]?.session == session { polls.removeValue(forKey: client)?.continuation.resume() }
            Task { try? await Task.sleep(for: .seconds(5)); self.expire(id) }
        }
    }
    private func expire(_ id: String) { pending.removeValue(forKey: id)?.continuation.resume(throwing: NavigationError.browserUnavailable) }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let handler: @Sendable (Data) async -> Data
    private var bytes = Data()
    private var finished = false
    init(connection: NWConnection, token: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.connection = connection; self.token = token; self.handler = handler
    }
    func start() {
        connection.start(queue: DispatchQueue(label: "moonshine.browser.request"))
        receive()
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [self] in connection.cancel() }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_000_000) { [self] data, _, complete, error in
            guard !finished else { return }
            if let data { bytes.append(data) }
            guard bytes.count <= 1_000_000, error == nil else { finish(status: "400 Bad Request"); return }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || bytes.count > 8192 { finish(status: "400 Bad Request") } else { receive() }; return
            }
            let header = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { finish(status: "400 Bad Request"); return }
                let key = parts[0].lowercased()
                guard fields[key] == nil else { finish(status: "400 Bad Request"); return }
                fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            guard fields["host"] == "127.0.0.1:\(BrowserBridge.port)", fields["transfer-encoding"] == nil else { finish(status: "403 Forbidden"); return }
            let origin = fields["origin"] ?? ""
            let allowedOrigin = origin.isEmpty || origin.hasPrefix("safari-web-extension://") || origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://")
            guard allowedOrigin else { finish(status: "403 Forbidden"); return }
            if lines.first == "OPTIONS /sync HTTP/1.1" { finish(status: "204 No Content", origin: origin); return }
            guard lines.first == "POST /sync HTTP/1.1", fields["authorization"] == "Bearer " + token,
                  let length = fields["content-length"].flatMap(Int.init), (0...950_000).contains(length) else { finish(status: "403 Forbidden"); return }
            let body = bytes[boundary.upperBound...]
            if body.count < length { if complete { finish(status: "400 Bad Request") } else { receive() }; return }
            guard body.count == length else { finish(status: "400 Bad Request"); return }
            finished = true
            Task { let reply = await handler(Data(body)); respond(status: "200 OK", data: reply, origin: origin) }
        }
    }
    private func finish(status: String, origin: String = "") { finished = true; respond(status: status, data: Data(), origin: origin) }
    private func respond(status: String, data: Data, origin: String) {
        let cors = origin.isEmpty ? "" : "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\n"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\n\(cors)Content-Length: \(data.count)\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [self] _ in connection.cancel() })
    }
}
