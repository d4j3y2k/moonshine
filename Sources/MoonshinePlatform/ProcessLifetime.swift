import AppKit
import Darwin

public enum ProcessLifetime {
    /// Some long-running system apps (including Finder on the tested Mac) have
    /// no NSRunningApplication.launchDate. Kernel process start time also prevents PID reuse.
    public static func start(of pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 {
            return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        }
        return NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970
    }
    public static func matches(pid: Int32, start: Double) -> Bool {
        guard let current = self.start(of: pid) else { return false }
        return current == start
    }
}
