import Foundation

let usage = """
usage: dynamo <command>

  status                 battery health and charging state
  limit <20-100>         set the charge limit
  sailing <0-30>         resume charging only after dropping this many % below the limit
  on | off               enable / disable limiting (off = macOS controls charging)
  topup [stop]           charge to 100% once, then return to the limit
  discharge [stop]       run from battery (while plugged in) down to the limit
  calibrate [stop]       discharge to 15%, charge to 100%, rest 1 h, return to the limit
  heat on|off [°C]       pause charging while the battery is hot (default 35°C)
  sleep on|off           keep the Mac awake while charging toward the limit
  led on|off             green MagSafe LED while holding at the limit
  lowpower <mode>        Low Power Mode: never | always | battery | adapter
  restore                (root) re-enable charging and adapter immediately
  daemon                 (root) run the background service

"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func updateConfig(_ change: (inout Config) -> Void) {
    guard var cfg = Config.load() else { fail("Cannot read \(Paths.config). Is Dynamo installed?") }
    change(&cfg)
    cfg = cfg.sanitized
    do { try cfg.save() } catch { fail("Cannot write \(Paths.config): \(error)") }
    var parts = [cfg.enabled ? "limit \(cfg.limit)%, resume at \(cfg.limit - cfg.sailing)%" : "limiting off"]
    if cfg.topUp { parts.append("topping up") }
    if cfg.discharge { parts.append("discharging") }
    if cfg.calibrate { parts.append("calibrating") }
    print(parts.joined(separator: ", "))
}

func onOff(_ s: String?) -> Bool {
    switch s { case "on": return true; case "off": return false; default: fail(usage) }
}

/// "stop" as the second argument turns a one-shot task off.
var stopRequested: Bool {
    let a = CommandLine.arguments.dropFirst(2).first
    if let a, a != "stop" { fail(usage) }
    return a == "stop"
}

func printStatus() {
    guard let b = BatteryInfo.read() else { fail("No battery found") }
    let cfg = Config.load()
    let st = DaemonStatus.load()

    func row(_ k: String, _ v: String) { print(k.padding(toLength: 18, withPad: " ", startingAt: 0) + v) }
    func time(_ m: Int?) -> String? { m.map { "\($0 / 60)h \($0 % 60)m" } }

    print("── Charge")
    row("Level", "\(b.percent)%  (\(b.currentCapacitymAh) mAh)")
    row("Power source", b.pluggedIn ? "Adapter" + (b.adapterWatts.map { " (\($0) W)" } ?? "") : "Battery")
    row("State", b.isCharging ? "Charging" : (b.pluggedIn ? "Not charging" : "Discharging"))
    if let t = time(b.minutesToFull), b.isCharging { row("Time to full", t) }
    if let t = time(b.minutesToEmpty) { row("Time remaining", t) }
    if let w = b.adapterInputWatts { row("Adapter input", String(format: "%.1f W", w)) }
    if let w = b.systemLoadWatts { row("Mac power draw", String(format: "%.1f W", w)) }
    row("Battery power", String(format: "%+.1f W", b.batteryWatts))

    print("── Health")
    let apple = AppleBatteryHealth.read()
    if let pct = apple?.maximumCapacity {
        row("Health", "\(pct)%" + (apple?.condition.map { "  (\($0))" } ?? ""))
    }
    row("Gauge capacity", "\(b.maxCapacitymAh) / \(b.designCapacitymAh) mAh  (\(b.rawHealthPercent)%)")
    row("Cycles", "\(b.cycleCount) of \(b.designCycleCount) rated")
    row("Temperature", String(format: "%.1f °C", b.temperatureC))
    row("Voltage", String(format: "%.2f V", b.voltage))
    if !b.cellVoltages.isEmpty {
        row("Cells", b.cellVoltages.map { "\($0) mV" }.joined(separator: ", ")
            + (b.cellImbalancemV.map { "  (Δ \($0) mV)" } ?? ""))
    }

    print("── Dynamo")
    if let cfg {
        row("Limit", cfg.enabled ? "\(cfg.limit)% (resume at \(cfg.limit - cfg.sailing)%)" : "off")
    } else {
        row("Limit", "not installed")
    }
    if let st {
        row("Service", st.isFresh ? st.reason : "not running (last seen \(st.updatedAt))")
        if let e = st.error { row("Error", e) }
    }
    if let lpm = LowPowerMode.current() {
        row("Low Power Mode", lpm.title + (ProcessInfo.processInfo.isLowPowerModeEnabled ? " (on now)" : " (off now)"))
    }
    row("SMC charging", ChargeControl.chargingInhibited.map { $0 ? "inhibited" : "allowed" } ?? "unknown")
    row("SMC adapter", ChargeControl.adapterDisabled.map { $0 ? "disabled" : "enabled" } ?? "unknown")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "daemon":
    Daemon().run()
case "status", nil:
    printStatus()
case "limit":
    guard let n = args.dropFirst().first.flatMap(Int.init), (20...100).contains(n) else { fail(usage) }
    updateConfig { $0.limit = n; $0.enabled = true }
case "sailing":
    guard let n = args.dropFirst().first.flatMap(Int.init), (0...30).contains(n) else { fail(usage) }
    updateConfig { $0.sailing = n }
case "on":
    updateConfig { $0.enabled = true }
case "off":
    updateConfig { $0.enabled = false; $0.topUp = false; $0.discharge = false; $0.calibrate = false }
case "topup":
    let stop = stopRequested
    updateConfig { $0.topUp = !stop; if !stop { $0.discharge = false; $0.calibrate = false } }
case "discharge":
    let stop = stopRequested
    updateConfig { $0.discharge = !stop; if !stop { $0.topUp = false; $0.calibrate = false } }
case "calibrate":
    let stop = stopRequested
    updateConfig { $0.calibrate = !stop; if !stop { $0.enabled = true; $0.topUp = false; $0.discharge = false } }
case "heat":
    let on = onOff(args.dropFirst().first)
    let temp = args.dropFirst(2).first.flatMap(Double.init)
    updateConfig { $0.heatProtection = on; if let temp { $0.heatMaxC = temp } }
case "sleep":
    let on = onOff(args.dropFirst().first)
    updateConfig { $0.preventSleepWhileCharging = on }
case "led":
    let on = onOff(args.dropFirst().first)
    updateConfig { $0.magsafeLED = on }
case "lowpower":
    guard let mode = args.dropFirst().first.flatMap(LowPowerMode.init(rawValue:)) else { fail(usage) }
    if geteuid() == 0 {
        print(mode.apply() ? "Low Power Mode: \(mode.title)" : "pmset failed")
    } else {
        updateConfig { $0.lowPowerRequest = mode }
        print("Requested Low Power Mode: \(mode.title) (applied within 5 s)")
    }
case "restore":
    guard geteuid() == 0 else { fail("restore needs root: sudo dynamo restore") }
    restoreDefaults()
    print("charging and adapter re-enabled")
case "help", "-h", "--help":
    print(usage)
default:
    fail(usage)
}
