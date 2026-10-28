import Foundation
import IOKit.ps
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
    /// Modification time and size of the config last parsed, to skip unchanged reads.
    private var configStamp: (mtime: timespec, size: off_t)?
    private var configWatch: DispatchSourceFileSystemObject?
    private var pendingConfigCheck: DispatchWorkItem?
    private var pluggedIn: Bool?

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
        watchPower()
        schedule(pluggedIn: true)
        tick()
        RunLoop.main.run()
        exit(0)
    }

    /// Every 5 s on power, where charging must stop right at the limit. On battery
    /// nothing charges, so every 30 s is plenty; plugging in or unplugging and setting
    /// changes trigger a check at once (watchPower, watchConfig).
    private func schedule(pluggedIn: Bool) {
        let interval: TimeInterval = pluggedIn ? 5 : 30
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval / 5  // lets macOS coalesce the wakeup with others
    }

    /// Checks right away when the adapter is connected or disconnected. macOS posts
    /// power source changes about once a minute on battery as well, so only a change
    /// in ExternalConnected leads to a full check.
    private func watchPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(ctx).takeUnretainedValue()
            let now = BatteryInfo.read(essentialsOnly: true)?.pluggedIn
            if now != nil && now != daemon.pluggedIn { daemon.tick() }
        }, ctx)?.takeRetainedValue() else {
            log("warning: no power source notifications; plugging in is noticed at the next check")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    /// Applies a change from the app or CLI right away, not at the next check (up to
    /// 30 s on battery). Config is saved in place, so the file itself can be watched;
    /// if it's ever replaced, the next check watches the new one.
    private func watchConfig() {
        let fd = open(Paths.config, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                src.cancel()
                self.configWatch = nil
            }
            // A save is a truncate then a write: let it finish, and check once.
            self.pendingConfigCheck?.cancel()
            let check = DispatchWorkItem { [weak self] in self?.tick() }
            self.pendingConfigCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatch = src
    }

    /// The config, tolerating a half-written file: if the file exists but doesn't
    /// parse, the app is mid-save, so keep using the last good copy. Parsed again
    /// only when the file has changed.
    private func loadConfig() -> Config? {
        var st = stat()
        guard stat(Paths.config, &st) == 0 else { return nil }
        if let c = lastGoodConfig, let s = configStamp, s.size == st.st_size,
           s.mtime.tv_sec == st.st_mtimespec.tv_sec, s.mtime.tv_nsec == st.st_mtimespec.tv_nsec {
            return c
        }
        guard let c = Config.load() else { return lastGoodConfig }
        lastGoodConfig = c
        configStamp = (st.st_mtimespec, st.st_size)
        return c
    }

    func tick() {
        if let since = asleepSince {
            // Timers don't fire while asleep, so a long-stale flag means the wake
            // notification was missed (e.g. a sleep that never happened).
            guard Date().timeIntervalSince(since) > 60 else { return }
            asleepSince = nil
        }
        if configWatch == nil { watchConfig() }
        guard let bat = BatteryInfo.read(essentialsOnly: true) else {
            writeStatus(mode: nil, reason: "Battery unreadable", error: "Could not read AppleSmartBattery",
                        inhibited: ChargeControl.chargingInhibited, adapterDisabled: ChargeControl.adapterDisabled)
            return
        }
        pluggedIn = bat.pluggedIn
        schedule(pluggedIn: bat.pluggedIn)
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

    /// Each SMC key is read once per tick (a read is a kernel round trip), and again
    /// only after a write, so the status reports what the SMC actually took.
    private func apply(_ d: Decision) {
        var error: String?
        var inhibited = ChargeControl.chargingInhibited
        var adapterDisabled = ChargeControl.adapterDisabled
        do {
            if inhibited != d.inhibitCharging {
                try ChargeControl.setChargingInhibited(d.inhibitCharging)
                inhibited = ChargeControl.chargingInhibited
                log("charging \(d.inhibitCharging ? "inhibited" : "enabled"): \(d.reason)")
            }
            if (adapterDisabled ?? false) != d.disableAdapter {
                try ChargeControl.setAdapterDisabled(d.disableAdapter)
                adapterDisabled = ChargeControl.adapterDisabled
                log("adapter \(d.disableAdapter ? "disabled" : "enabled"): \(d.reason)")
            }
        } catch let e {
            log("\(e)")
            error = "\(e)"
        }
        applyLED(green: d.greenLED)
        setSleepPrevented(d.preventSleep)
        writeStatus(mode: d.mode, reason: d.reason, error: error, inhibited: inhibited, adapterDisabled: adapterDisabled)
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

    private func writeStatus(mode: ChargeMode?, reason: String, error: String?, inhibited: Bool?, adapterDisabled: Bool?) {
        let s = DaemonStatus(updatedAt: Date(), mode: mode,
                             chargingInhibited: inhibited ?? false,
                             adapterDisabled: adapterDisabled ?? false,
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
        lastStatusWrite = Date()
        // Nothing new: touching the file is enough to show we're alive (readers count
        // its date, see DaemonStatus.load), and costs a fraction of rewriting it.
        if !changed && utimes(Paths.status, nil) == 0 { return }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: URL(fileURLWithPath: Paths.status), options: .atomic)
            chmod(Paths.status, 0o644)
        }
        lastStatus = s
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
