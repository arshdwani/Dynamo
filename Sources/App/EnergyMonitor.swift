import AppKit
import Darwin

struct AppEnergy: Identifiable {
    var id: String          // bundle path, or executable path for plain processes
    var name: String
    var bundlePath: String?
    var watts: Double       // smoothed
    var cpuPercent: Double  // smoothed, 100 = one full core
}

/// Per-app power from the kernel's per-process energy counters (`ri_energy_nj`),
/// which is the same source Activity Monitor's energy figures build on. Helper
/// processes are folded into the outermost .app bundle they live in. Only
/// processes owned by this user are readable, which covers every app you run.
final class EnergyMonitor {
    /// Apps above this smoothed draw count as "using significant energy".
    static let significantWatts = 0.8

    private struct Sample { var energy: UInt64; var cpu: UInt64 }
    private var last: [pid_t: Sample] = [:]
    private var lastTime: UInt64 = 0
    private var paths: [pid_t: String] = [:]
    /// Display names by key: looking them up for every app took most of each sample.
    private var names: [String: String] = [:]
    private var smoothed: [String: (watts: Double, cpu: Double)] = [:]
    private let timebase: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Call periodically; returns apps sorted by power, highest first.
    func sample() -> [AppEnergy] {
        let now = mach_absolute_time()
        let seconds = lastTime == 0 ? 0 : Double(now - lastTime) * timebase / 1e9
        var current: [pid_t: Sample] = [:]
        var perApp: [String: (watts: Double, cpu: Double)] = [:]

        for pid in Self.allPids() where pid > 0 {
            guard let s = Self.usage(pid) else { continue }
            current[pid] = s
            guard seconds > 0, let prev = last[pid], s.energy >= prev.energy, s.cpu >= prev.cpu else { continue }
            let key = appKey(for: pid)
            let watts = Double(s.energy - prev.energy) / 1e9 / seconds
            let cpu = Double(s.cpu - prev.cpu) * timebase / 1e9 / seconds * 100
            perApp[key, default: (0, 0)].watts += watts
            perApp[key, default: (0, 0)].cpu += cpu
        }
        last = current
        lastTime = now
        paths = paths.filter { current[$0.key] != nil }
        guard seconds > 0 else { return [] }

        // Exponential smoothing with a ~30 s time constant so brief spikes don't flicker.
        // After a long gap (panel was closed) the new reading is already a long
        // average, so it mostly replaces the old one.
        let alpha = 1 - exp(-seconds / 30)
        var next: [String: (watts: Double, cpu: Double)] = [:]
        for key in Set(perApp.keys).union(smoothed.keys) {
            let cur = perApp[key] ?? (0, 0)
            let old = smoothed[key] ?? cur
            let v = (old.watts + alpha * (cur.watts - old.watts), old.cpu + alpha * (cur.cpu - old.cpu))
            if v.0 > 0.005 || perApp[key] != nil { next[key] = v }
        }
        smoothed = next
        names = names.filter { smoothed[$0.key] != nil }

        return smoothed.map { key, v in
            AppEnergy(id: key, name: name(for: key), bundlePath: key.hasSuffix(".app") ? key : nil,
                      watts: v.watts, cpuPercent: v.cpu)
        }
        .sorted { $0.watts > $1.watts }
    }

    private func name(for key: String) -> String {
        if let n = names[key] { return n }
        let n = key.hasSuffix(".app")
            ? FileManager.default.displayName(atPath: key).replacingOccurrences(of: ".app", with: "")
            : (key as NSString).lastPathComponent
        names[key] = n
        return n
    }

    private func appKey(for pid: pid_t) -> String {
        if let p = paths[pid] { return p }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
        let key: String
        if let r = path.range(of: ".app/") {
            key = String(path[..<r.lowerBound]) + ".app"
        } else {
            key = path
        }
        paths[pid] = key
        return key
    }

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return Array(buf.prefix(Int(max(0, got))))
    }

    private static func usage(_ pid: pid_t) -> Sample? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard rc == 0 else { return nil }
        return Sample(energy: ri.ri_energy_nj, cpu: ri.ri_user_time + ri.ri_system_time)
    }
}
