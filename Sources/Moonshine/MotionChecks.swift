import AppKit
import SwiftUI
import QuartzCore
import Darwin
import MoonshineCore

/// Opt-in synthetic motion benchmark. Measures main-thread display-link delivery and
/// process CPU, not compositor-presented frames. Never reads or captures other apps.
@MainActor private final class MotionCadence: NSObject {
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private(set) var intervals: [Double] = []
    private(set) var expected: [Double] = []
    func start(window: NSWindow) {
        previous = nil; intervals = []; expected = []
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previous { intervals.append((now - previous) * 1000) }
        previous = now
        expected.append((link.targetTimestamp - link.timestamp) * 1000)
    }
    func stop() { link?.invalidate(); link = nil }
}

private func processCPU() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}

@MainActor func runMotionChecks(panel: PanelController, model: AppModel) async throws {
    let windows = (0..<31).map { index -> WorkspaceItem in
        var item = AppModel.fixtures[index % 3]
        item.id = "motion-window-\(index)"; item.title = "Synthetic window \(index)"
        item.recency = index
        return item
    }
    let tabs = (0..<64).map { index -> WorkspaceItem in
        var item = AppModel.fixtures[3 + index % 4]; item.id = "motion-tab-\(index)"; return item
    }
    model.search.update(windows + tabs); model.previews = FixturePreviews.make(for: windows)
    panel.present(focus: false)
    defer { panel.dismiss(restore: false) }
    panel.panel.ignoresMouseEvents = true
    try await Task.sleep(for: .milliseconds(400))
    var allIntervals: [Double] = [], expected: [Double] = [], cpu: [Double] = []
    let cadence = MotionCadence()
    for cycle in 0..<8 {
        model.spread = false; model.isSettling = true
        panel.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        cadence.start(window: panel.panel)
        let started = processCPU()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { model.spread = true }
        try await Task.sleep(for: .milliseconds(650))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) { model.spread = false }
        try await Task.sleep(for: .milliseconds(400))
        cadence.stop()
        if cycle > 0 { // One warm-up cycle excludes first-use font/material setup.
            cpu.append(processCPU() - started); allIntervals += cadence.intervals; expected += cadence.expected
        }
    }
    model.spread = true; model.isSettling = false
    func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    let interval = percentile(expected, 0.5)
    print("Synthetic motion: 31 windows / 64 tabs; 7 measured open-close cycles; display \(Int(panel.panel.frame.width))x\(Int(panel.panel.frame.height)) points")
    print(String(format: "Main display-link delivery: samples=%d expected=%.2fms p50=%.2fms p95=%.2fms max=%.2fms gaps_over_1.5x=%d", allIntervals.count, interval, percentile(allIntervals, 0.5), percentile(allIntervals, 0.95), allIntervals.max() ?? 0, allIntervals.filter { $0 > interval * 1.5 }.count))
    print(String(format: "Process CPU per open-close cycle: p50=%.2fms p95=%.2fms", percentile(cpu, 0.5), percentile(cpu, 0.95)))
    print("Display-link delivery is a main-thread cadence proxy, not a GPU/compositor frame-rate measurement.")
}
