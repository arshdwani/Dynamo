import Foundation

/// Battery samples kept by the daemon (one every 5 minutes, last 48 hours).
struct HistorySample: Codable, Identifiable {
    var t: Date
    var pct: Int
    var tempC: Double
    var watts: Double
    var plugged: Bool
    var id: Date { t }
}

enum History {
    static let path = Paths.dir + "/history.json"
    static let interval: TimeInterval = 300
    static let keep: TimeInterval = 48 * 3600

    static func load() -> [HistorySample] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([HistorySample].self, from: data)) ?? []
    }

    static func save(_ samples: [HistorySample]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(samples) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o644)
    }

    /// Appends a sample if the last one is older than `interval`; returns the trimmed list.
    static func record(_ b: BatteryInfo, into samples: inout [HistorySample], now: Date = Date()) -> Bool {
        if let last = samples.last, now.timeIntervalSince(last.t) < interval { return false }
        samples.append(HistorySample(t: now, pct: b.percent, tempC: b.temperatureC,
                                     watts: (b.batteryWatts * 10).rounded() / 10, plugged: b.pluggedIn))
        samples.removeAll { now.timeIntervalSince($0.t) > keep }
        return true
    }
}
