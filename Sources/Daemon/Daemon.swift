import Foundation
import IOKit.pwr_mgt

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(ts) \(msg)\n".data(using: .utf8)!)
}

/// Daemon-owned state that must survive restarts (calibration runs for hours).
private struct PersistedState: Codable {
    var calibration: Calibration?

    static func load() -> PersistedState {
        guard let data = FileManager.default.contents(atPath: Paths.state) else { return PersistedState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.state), options: .atomic)
    }
}

final class Daemon {
    private var state = PolicyState()
    private var lastGoodConfig: Config?
    private var history = History.load()
    private var assertion: IOPMAssertionID = 0
    private var ledOverridden = false
    private var ledFailed = false
    private var lastStatus: DaemonStatus?
    private var lastStatusWrite = Date.distantPast
    private var event: (text: String, at: Date)?
    private var powerPort: IONotificationPortRef?
    fileprivate var rootPort: io_connect_t = 0
    private var asleepSince: Date?
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        state.wasInhibited = ChargeControl.chargingInhibited ?? false
        state.calibration = PersistedState.load().calibration
    }

    func run() -> Never {
        guard geteuid() == 0 else {
            log("daemon must run as root")
            exit(1)
        }
        log("Dynamo daemon started (\(ChargeControl.keySummary))")

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.shutdown() }
            src.resume()
            signalSources.append(src)
        }

        registerForSleep()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        RunLoop.main.run()
        exit(0)
    }

    /// The config, tolerating a half-written file: if the file exists but doesn't
    /// parse, the app is mid-save, so keep using the last good copy.
    private func loadConfig() -> Config? {
        if let c = Config.load() {
            lastGoodConfig = c
            return c
        }
        return Config.exists ? lastGoodConfig : nil
    }

    func tick() {
        if let since = asleepSince {
            // Timers don't fire while asleep, so a long-stale flag means the wake
            // notification was missed (e.g. a sleep that never happened).
            guard Date().timeIntervalSince(since) > 60 else { return }
            asleepSince = nil
        }
        guard let bat = BatteryInfo.read() else {
            writeStatus(mode: nil, reason: "Battery unreadable", error: "Could not read AppleSmartBattery")
            return
        }
        if History.record(bat, into: &history) { History.save(history) }

        guard var cfg = loadConfig()?.sanitized else {
            // No config at all: fail safe by leaving charging to macOS.
            apply(Decision(mode: .noConfig, inhibitCharging: false, reason: "No config: macOS controls charging"))
            return
        }

        let d = decide(cfg, bat, state)
        if d.next.calibration != state.calibration {
            if let c = d.next.calibration { log("calibration step \(c.phase.step)/4: \(c.phase.rawValue)") }
            PersistedState(calibration: d.next.calibration).save()
        }
        state = d.next
        apply(d)

        let appliedLowPower = cfg.lowPowerRequest
        if let mode = appliedLowPower {
            log("low power mode -> \(mode.rawValue): \(mode.apply() ? "ok" : "pmset failed")")
        }
        let endTopUp = d.finishTopUp && cfg.topUp
        let endDischarge = d.finishDischarge && cfg.discharge
        let endCalibration = d.finishCalibration && cfg.calibrate
        if cfg.enabled {
            if endTopUp { finished("Top up complete: battery at \(bat.percent)%") }
            if endDischarge { finished("Discharge complete: battery at \(bat.percent)%") }
            if endCalibration { finished("Calibration complete: battery at \(bat.percent)%") }
        }
        guard appliedLowPower != nil || endTopUp || endDischarge || endCalibration else { return }

        // Re-read right before writing and clear only what this tick consumed, so a
        // change the app made in the meantime isn't lost.
        cfg = Config.load() ?? cfg
        if cfg.lowPowerRequest == appliedLowPower { cfg.lowPowerRequest = nil }
        if endTopUp { cfg.topUp = false }
        if endDischarge { cfg.discharge = false }
        if endCalibration { cfg.calibrate = false }
        try? cfg.save()
        lastGoodConfig = cfg
    }

    private func finished(_ text: String) {
        log(text)
        event = (text, Date())
    }

    private func apply(_ d: Decision) {
        var error: String?
        do {
            if ChargeControl.chargingInhibited != d.inhibitCharging {
                try ChargeControl.setChargingInhibited(d.inhibitCharging)
                log("charging \(d.inhibitCharging ? "inhibited" : "enabled"): \(d.reason)")
            }
            if (ChargeControl.adapterDisabled ?? false) != d.disableAdapter {
                try ChargeControl.setAdapterDisabled(d.disableAdapter)
                log("adapter \(d.disableAdapter ? "disabled" : "enabled"): \(d.reason)")
            }
        } catch let e {
            log("\(e)")
            error = "\(e)"
        }
        applyLED(green: d.greenLED)
        setSleepPrevented(d.preventSleep)
        writeStatus(mode: d.mode, reason: d.reason, error: error)
    }

    /// Only touches the LED while overriding it, so macOS keeps control otherwise.
    /// Cosmetic, so failures are logged once rather than reported as errors.
    private func applyLED(green: Bool) {
        do {
            if green {
                if ChargeControl.led != ChargeControl.LED.green.rawValue { try ChargeControl.setLED(.green) }
                ledOverridden = true
            } else if ledOverridden {
                try ChargeControl.setLED(.system)
                ledOverridden = false
            }
        } catch {
            if !ledFailed { log("MagSafe LED: \(error)") }
            ledFailed = true
        }
    }

    private func setSleepPrevented(_ on: Bool) {
        if on && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Dynamo: charging/discharging toward target" as CFString,
                                        &assertion)
        } else if !on && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func writeStatus(mode: ChargeMode?, reason: String, error: String?) {
        let s = DaemonStatus(updatedAt: Date(), mode: mode,
                             chargingInhibited: ChargeControl.chargingInhibited ?? false,
                             adapterDisabled: ChargeControl.adapterDisabled ?? false,
                             sleepPrevented: assertion != 0,
                             reason: reason, error: error,
                             calibration: state.calibration,
                             event: event?.text, eventAt: event?.at)
        let changed = lastStatus.map {
            $0.mode != s.mode || $0.chargingInhibited != s.chargingInhibited || $0.adapterDisabled != s.adapterDisabled
                || $0.sleepPrevented != s.sleepPrevented || $0.reason != s.reason || $0.error != s.error
                || $0.calibration != s.calibration || $0.eventAt != s.eventAt
        } ?? true
        guard changed || Date().timeIntervalSince(lastStatusWrite) > 20 else { return }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: URL(fileURLWithPath: Paths.status), options: .atomic)
            chmod(Paths.status, 0o644)
        }
        lastStatus = s
        lastStatusWrite = Date()
    }

    // MARK: Sleep / wake

    private func registerForSleep() {
        var notifier: io_object_t = 0
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(ctx, &powerPort, powerCallback, &notifier)
        if rootPort == 0 { log("warning: could not register for sleep notifications"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(powerPort).takeUnretainedValue(),
                           .defaultMode)
    }

    /// Before sleeping, stop charging so the Mac can't charge past the limit while
    /// we aren't running, and give the adapter back. Charging stays on when the goal
    /// is a full battery (top up, or the full phases of calibration).
    fileprivate func willSleep() {
        asleepSince = Date()
        let cfg = loadConfig()?.sanitized
        let wantsFull = cfg?.topUp == true
            || state.calibration?.phase == .chargeFull || state.calibration?.phase == .holdFull
        do {
            if ChargeControl.adapterDisabled == true { try ChargeControl.setAdapterDisabled(false) }
            if let cfg, cfg.enabled, cfg.limit < 100, !wantsFull {
                try ChargeControl.setChargingInhibited(true)
                state.wasInhibited = true
            }
        } catch { log("sleep prep failed: \(error)") }
        setSleepPrevented(false)
        log("going to sleep")
    }

    fileprivate func didWake() {
        asleepSince = nil
        log("woke up")
        tick()
    }

    // MARK: Shutdown

    func shutdown() {
        log("stopping; handing charging back to macOS")
        restoreDefaults()
        setSleepPrevented(false)
        exit(0)
    }
}

/// Re-enables charging and the adapter and hands the LED back to macOS.
/// Used on daemon stop and by `dynamo restore`.
func restoreDefaults() {
    try? ChargeControl.setChargingInhibited(false)
    try? ChargeControl.setAdapterDisabled(false)
    try? ChargeControl.setLED(.system)
}

// iokit_common_msg(x) = sys_iokit | sub_iokit_common | x; the C macros don't import into Swift.
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

private func powerCallback(_ refCon: UnsafeMutableRawPointer?, _ service: io_service_t,
                           _ messageType: UInt32, _ messageArgument: UnsafeMutableRawPointer?) {
    guard let refCon else { return }
    let daemon = Unmanaged<Daemon>.fromOpaque(refCon).takeUnretainedValue()
    let arg = Int(bitPattern: messageArgument)
    switch messageType {
    case kMsgCanSystemSleep:
        IOAllowPowerChange(daemon.rootPort, arg)
    case kMsgSystemWillSleep:
        daemon.willSleep()
        IOAllowPowerChange(daemon.rootPort, arg)
    case kMsgSystemHasPoweredOn:
        daemon.didWake()
    default:
        break
    }
}
