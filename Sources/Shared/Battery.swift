import Foundation
import IOKit

/// Snapshot of the AppleSmartBattery registry entry. Readable as any user.
struct BatteryInfo {
    // Charge
    var percent: Int
    var pluggedIn: Bool
    var isCharging: Bool
    var fullyCharged: Bool
    var currentCapacitymAh: Int
    var minutesToFull: Int?
    var minutesToEmpty: Int?

    // Health
    var cycleCount: Int
    var designCycleCount: Int
    var maxCapacitymAh: Int
    var nominalCapacitymAh: Int
    var designCapacitymAh: Int
    var cellDisconnects: Int
    var permanentFailure: Bool

    // Electrical / thermal
    var temperatureC: Double
    var voltage: Double
    var amperage: Int
    var cellVoltages: [Int]
    var systemLoadWatts: Double?
    /// Power actually drawn from the adapter right now (not its rating).
    var adapterInputWatts: Double?

    // Adapter
    var adapterWatts: Int?
    var adapterName: String?
    var chargerCurrent: Int?

    // History
    var dailyMinSoc: Int?
    var dailyMaxSoc: Int?
    var lifetimeMaxTempC: Int?
    var lifetimeMinTempC: Int?

    // Identity
    var serial: String?
    var gaugeName: String?

    /// Raw gauge capacity versus design. macOS's own figure is AppleBatteryHealth.
    var rawHealthPercent: Int {
        designCapacitymAh > 0 ? Int((Double(maxCapacitymAh) / Double(designCapacitymAh) * 100).rounded()) : 0
    }

    /// Watts flowing into (+) or out of (-) the battery.
    var batteryWatts: Double { voltage * Double(amperage) / 1000 }

    var cellImbalancemV: Int? {
        guard let lo = cellVoltages.min(), let hi = cellVoltages.max(), cellVoltages.count > 1 else { return nil }
        return hi - lo
    }

    /// What the daemon's policy and history and the menu bar icon need. Copying just
    /// these is about 6x cheaper than the whole entry (0.25 vs 1.6 ms on a cold wakeup),
    /// which matters for code that runs all day.
    static let essentialKeys = ["CurrentCapacity", "ExternalConnected", "IsCharging", "FullyCharged",
                                "Temperature", "Voltage", "InstantAmperage", "AvgTimeToEmpty", "AvgTimeToFull"]

    /// With `essentialsOnly`, fields outside `essentialKeys` are left zero or nil.
    static func read(essentialsOnly: Bool = false) -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        var d: [String: Any] = [:]
        if essentialsOnly {
            for k in essentialKeys {
                d[k] = IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard !d.isEmpty else { return nil }
        } else {
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let all = props?.takeRetainedValue() as? [String: Any] else { return nil }
            d = all
        }

        func num(_ dict: [String: Any]?, _ k: String) -> Int? { (dict?[k] as? NSNumber)?.intValue }
        func int(_ k: String) -> Int { num(d, k) ?? 0 }
        func bool(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }
        /// 65535 means "unknown / not applicable".
        func minutes(_ k: String) -> Int? { num(d, k).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil } }

        let data = d["BatteryData"] as? [String: Any]
        let lifetime = data?["LifetimeData"] as? [String: Any]
        let adapter = d["AdapterDetails"] as? [String: Any]
        let charger = d["ChargerData"] as? [String: Any]
        let telemetry = d["PowerTelemetryData"] as? [String: Any]
        let pluggedIn = bool("ExternalConnected")

        return BatteryInfo(
            percent: int("CurrentCapacity"),
            pluggedIn: pluggedIn,
            isCharging: bool("IsCharging"),
            fullyCharged: bool("FullyCharged"),
            currentCapacitymAh: int("AppleRawCurrentCapacity"),
            minutesToFull: minutes("AvgTimeToFull"),
            minutesToEmpty: pluggedIn ? nil : minutes("AvgTimeToEmpty"),
            cycleCount: int("CycleCount"),
            designCycleCount: num(d, "DesignCycleCount9C") ?? 1000,
            maxCapacitymAh: int("AppleRawMaxCapacity"),
            nominalCapacitymAh: int("NominalChargeCapacity"),
            designCapacitymAh: int("DesignCapacity"),
            cellDisconnects: int("BatteryCellDisconnectCount"),
            permanentFailure: int("PermanentFailureStatus") != 0,
            temperatureC: Double(int("Temperature")) / 100,
            voltage: Double(int("Voltage")) / 1000,
            amperage: Int(Int16(truncatingIfNeeded: int("InstantAmperage"))),
            cellVoltages: (data?["CellVoltage"] as? [NSNumber])?.map(\.intValue) ?? [],
            systemLoadWatts: num(telemetry, "SystemLoad").map { Double($0) / 1000 },
            adapterInputWatts: pluggedIn ? num(telemetry, "SystemPowerIn").map { Double($0) / 1000 } : nil,
            adapterWatts: pluggedIn ? num(adapter, "Watts") : nil,
            adapterName: pluggedIn ? adapter?["Description"] as? String : nil,
            chargerCurrent: num(charger, "ChargingCurrent"),
            dailyMinSoc: num(data, "DailyMinSoc"),
            dailyMaxSoc: num(data, "DailyMaxSoc"),
            lifetimeMaxTempC: num(lifetime, "MaximumTemperature"),
            lifetimeMinTempC: num(lifetime, "MinimumTemperature"),
            serial: d["Serial"] as? String ?? data?["Serial"] as? String,
            gaugeName: d["DeviceName"] as? String
        )
    }
}

/// The "Maximum Capacity" and "Condition" macOS shows in System Settings. Apple derives
/// these from its own health model rather than the raw gauge, so they are only
/// available through system_profiler. Takes ~0.2 s; call off the main thread.
struct AppleBatteryHealth {
    var maximumCapacity: Int?
    var condition: String?

    static func read() -> AppleBatteryHealth? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let h = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            let pct = (h["sppower_battery_health_maximum_capacity"] as? String)
                .flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            return AppleBatteryHealth(maximumCapacity: pct,
                                      condition: h["sppower_battery_health"] as? String)
        }
        return nil
    }
}
