import Foundation

/// Monotonic elapsed time, unaffected by changes to the system clock.
public struct LatencyTimer: Sendable {
    private let start = ProcessInfo.processInfo.systemUptime
    public init() {}
    public var milliseconds: Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
}

public actor Metrics {
    public static let shared = Metrics()
    private var samples: [String: [Double]] = [:]
    private var counters: [String: Int] = [:]
    private var sizes: [Int] = []
    public func payload(bytes: Int) { sizes.append(bytes); if sizes.count > 500 { sizes.removeFirst() } }
    public func record(_ name: String, milliseconds: Double) {
        if CommandLine.arguments.contains("--inspect") {
            FileHandle.standardError.write(Data(String(format: "Timing %@: %.2f ms\n", name, milliseconds).utf8))
        }
        samples[name, default: []].append(milliseconds)
        if samples[name, default: []].count > 500 { samples[name]?.removeFirst() }
    }
    public func count(_ name: String) { counters[name, default: 0] += 1 }
    public func report() -> String {
        let timings = samples.keys.sorted().map { name -> String in
            let values = samples[name]!.sorted(), n = values.count
            let median = values[(n - 1) / 2]
            let p95 = n >= 20 ? String(format: ", p95 %.1f ms", values[min(n - 1, Int(ceil(Double(n) * 0.95)) - 1)]) : ", p95 withheld (n < 20)"
            return String(format: "%@: n=%d, p50 %.1f ms", name, n, median) + p95
        }
        let payload = sizes.isEmpty ? [] : ["payload: n=\(sizes.count), min=\(sizes.min()!) bytes, max=\(sizes.max()!) bytes"]
        return (timings + payload + counters.keys.sorted().map { "\($0): \(counters[$0]!)" }).joined(separator: "\n")
    }
}
