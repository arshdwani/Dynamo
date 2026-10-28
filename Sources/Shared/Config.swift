import Foundation

/// Shared between the root daemon and the menu bar app via JSON files in a
/// root-owned directory. config.json is root:staff 0664 so the app can write it
/// without root; status.json and state.json are written by the daemon only.
enum Paths {
    static let dir = "/Library/Application Support/Dynamo"
    static let config = dir + "/config.json"
    static let status = dir + "/status.json"
    static let state = dir + "/state.json"
}

struct Config: Codable, Equatable {
    /// Master switch. When false the daemon leaves charging fully to macOS.
    var enabled = true
    /// Stop charging at this percentage.
    var limit = 80
    /// Resume charging only once the battery falls this many points below the limit.
    var sailing = 5
    /// One-shot: charge to 100%, then switch itself off.
    var topUp = false
    /// One-shot: while plugged in, run from battery until it reaches the limit.
    var discharge = false
    /// Run the calibration cycle (15% → 100% → hold 1 h → limit), then switch itself off.
    var calibrate = false
    /// Pause charging while the battery is hotter than `heatMaxC`.
    var heatProtection = false
    var heatMaxC = 35.0
    /// Keep the Mac awake while it is charging up toward the limit, so it does not
    /// sleep with charging enabled and overshoot.
    var preventSleepWhileCharging = true
    /// Turn the MagSafe LED green while the battery is being held at the limit.
    var magsafeLED = true
    /// One-shot request from the app; the daemon applies it with pmset and clears it.
    var lowPowerRequest: LowPowerMode?

    init() {}

    /// Every key is optional so configs written by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        sailing = try c.decodeIfPresent(Int.self, forKey: .sailing) ?? d.sailing
        topUp = try c.decodeIfPresent(Bool.self, forKey: .topUp) ?? d.topUp
        discharge = try c.decodeIfPresent(Bool.self, forKey: .discharge) ?? d.discharge
        calibrate = try c.decodeIfPresent(Bool.self, forKey: .calibrate) ?? d.calibrate
        heatProtection = try c.decodeIfPresent(Bool.self, forKey: .heatProtection) ?? d.heatProtection
        heatMaxC = try c.decodeIfPresent(Double.self, forKey: .heatMaxC) ?? d.heatMaxC
        preventSleepWhileCharging = try c.decodeIfPresent(Bool.self, forKey: .preventSleepWhileCharging)
            ?? d.preventSleepWhileCharging
        magsafeLED = try c.decodeIfPresent(Bool.self, forKey: .magsafeLED) ?? d.magsafeLED
        lowPowerRequest = try? c.decodeIfPresent(LowPowerMode.self, forKey: .lowPowerRequest)
    }

    static func load() -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: Paths.config) }

    var sanitized: Config {
        var c = self
        c.limit = min(100, max(20, c.limit))
        c.sailing = min(30, max(0, c.sailing), c.limit - 10)
        c.heatMaxC = min(60, max(25, c.heatMaxC))
        return c
    }

    /// Writes in place (not atomically) so the file keeps the installer's owner and
    /// mode. Readers keep their last good copy if they catch a half-written file.
    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        guard let h = FileHandle(forWritingAtPath: Paths.config) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? h.close() }
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: data)
    }
}

/// What the daemon is doing, for the UI.
enum ChargeMode: String, Codable {
    case off            // limiting disabled
    case noLimit        // limit is 100%
    case onBattery
    case charging       // charging toward the limit
    case holding        // at/above the limit, charging paused
    case sailing        // below the limit but inside the sailing band
    case heatPaused
    case topUp
    case discharging
    case calibrating
    case noConfig
}

/// Written by the daemon after every evaluation; read by the app and CLI.
struct DaemonStatus: Codable {
    var updatedAt: Date
    var mode: ChargeMode?
    var chargingInhibited: Bool
    var adapterDisabled: Bool
    var sleepPrevented: Bool
    var reason: String
    var error: String?
    var calibration: Calibration?
    /// Most recent finished task ("Top up complete", ...), for notifications.
    var event: String?
    var eventAt: Date?

    /// When nothing has changed the daemon only touches the file (far cheaper than
    /// rewriting it), so the file's modification date counts as `updatedAt` too.
    static func load() -> DaemonStatus? {
        guard let data = FileManager.default.contents(atPath: Paths.status) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var s = try? dec.decode(DaemonStatus.self, from: data) else { return nil }
        var st = stat()
        if stat(Paths.status, &st) == 0 {
            let touched = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            s.updatedAt = max(s.updatedAt, touched)
        }
        return s
    }

    var isFresh: Bool { Date().timeIntervalSince(updatedAt) < 60 }
}
