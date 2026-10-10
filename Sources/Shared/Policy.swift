import Foundation

/// Calibration: run the battery down, fill it, rest it full, then return to the
/// limit. Gives the fuel gauge fresh full/empty reference points.
struct Calibration: Codable, Equatable {
    enum Phase: String, Codable, CaseIterable {
        case dischargeLow, chargeFull, holdFull, dischargeToLimit

        var step: Int { Self.allCases.firstIndex(of: self)! + 1 }
    }

    var phase: Phase
    var since: Date

    static let lowTarget = 15
    static let holdSeconds: TimeInterval = 3600
}

/// What the daemon carries from one evaluation to the next.
struct PolicyState: Equatable {
    var wasInhibited = false
    var heatPaused = false
    var calibration: Calibration?
}

struct Decision: Equatable {
    var mode: ChargeMode
    var inhibitCharging: Bool
    var disableAdapter = false
    var preventSleep = false
    var reason: String
    /// MagSafe LED override: true = green, false = leave it to macOS.
    var greenLED = false
    var next = PolicyState()
    var finishTopUp = false
    var finishDischarge = false
    var finishCalibration = false
}

/// Decides the charging state from the config, the battery, and the previous state.
/// Pure, so it can be tested without touching the SMC.
func decide(_ cfg: Config, _ bat: BatteryInfo, _ state: PolicyState, now: Date = Date()) -> Decision {
    let pct = bat.percent
    let plugged = bat.pluggedIn

    guard cfg.enabled else {
        return Decision(mode: .off, inhibitCharging: false, reason: "Off: macOS controls charging",
                        finishTopUp: cfg.topUp, finishDischarge: cfg.discharge, finishCalibration: cfg.calibrate)
    }

    // Calibration overrides everything else while it runs.
    var finishCalibration = false
    if cfg.calibrate {
        let start = state.calibration ?? Calibration(phase: .dischargeLow, since: now)
        if let cal = advance(start, bat, limit: cfg.limit, now: now) {
            var d = calibrationDecision(cal, bat, limit: cfg.limit, now: now)
            d.next = PolicyState(wasInhibited: d.inhibitCharging, calibration: cal)
            d.finishTopUp = cfg.topUp
            d.finishDischarge = cfg.discharge
            return d
        }
        finishCalibration = true
    }

    var finishTopUp = false
    if cfg.topUp {
        if pct >= 100 || bat.fullyCharged {
            finishTopUp = true
        } else {
            return Decision(mode: plugged ? .topUp : .onBattery, inhibitCharging: false,
                            preventSleep: plugged && cfg.preventSleepWhileCharging,
                            reason: plugged ? "Topping up to 100%" : "Top up waiting for power",
                            finishCalibration: finishCalibration)
        }
    }

    var finishDischarge = false
    if cfg.discharge && plugged {
        if pct > cfg.limit {
            return Decision(mode: .discharging, inhibitCharging: true, disableAdapter: true, preventSleep: true,
                            reason: "Discharging to \(cfg.limit)%",
                            next: PolicyState(wasInhibited: true),
                            finishTopUp: finishTopUp, finishCalibration: finishCalibration)
        }
        finishDischarge = true
    }

    // Heat protection with 2 °C of hysteresis so it doesn't flap at the threshold.
    let heatPaused = cfg.heatProtection
        && bat.temperatureC >= (state.heatPaused ? cfg.heatMaxC - 2 : cfg.heatMaxC)

    let resumeAt = cfg.limit - cfg.sailing
    var d: Decision
    if cfg.limit >= 100 {
        d = Decision(mode: .noLimit, inhibitCharging: false, reason: "No limit (100%)")
    } else if heatPaused {
        d = Decision(mode: .heatPaused, inhibitCharging: true,
                     reason: String(format: "Paused: battery is hot (%.0f°C)", bat.temperatureC))
    } else if pct >= cfg.limit {
        d = Decision(mode: .holding, inhibitCharging: true, reason: "Holding at \(cfg.limit)%")
    } else if pct <= resumeAt || !state.wasInhibited {
        d = Decision(mode: .charging, inhibitCharging: false, reason: "Charging to \(cfg.limit)%")
    } else {
        d = Decision(mode: .sailing, inhibitCharging: true, reason: "Sailing: resumes charging at \(resumeAt)%")
    }

    if !plugged {
        d.mode = .onBattery
        d.reason = "On battery"
    }
    d.preventSleep = plugged && !d.inhibitCharging && cfg.limit < 100 && cfg.preventSleepWhileCharging
    d.greenLED = cfg.magsafeLED && plugged && (d.mode == .holding || d.mode == .sailing)
    d.next = PolicyState(wasInhibited: d.inhibitCharging, heatPaused: heatPaused)
    d.finishTopUp = finishTopUp
    d.finishDischarge = finishDischarge
    d.finishCalibration = finishCalibration
    return d
}

/// Moves calibration forward; nil when it has finished.
func advance(_ c: Calibration, _ bat: BatteryInfo, limit: Int, now: Date) -> Calibration? {
    var c = c
    // Loop so several phases can complete in one evaluation (e.g. starting below 15%).
    for _ in 0..<4 {
        let next: Calibration.Phase?
        switch c.phase {
        case .dischargeLow:
            next = bat.percent <= Calibration.lowTarget ? .chargeFull : nil
        case .chargeFull:
            next = bat.percent >= 100 || bat.fullyCharged ? .holdFull : nil
        case .holdFull:
            if !bat.pluggedIn { next = .chargeFull }  // must rest full on power
            else { next = now.timeIntervalSince(c.since) >= Calibration.holdSeconds ? .dischargeToLimit : nil }
        case .dischargeToLimit:
            if bat.percent <= limit || limit >= 100 { return nil }
            next = nil
        }
        guard let next else { return c }
        c = Calibration(phase: next, since: now)
    }
    return c
}

private func calibrationDecision(_ c: Calibration, _ bat: BatteryInfo, limit: Int, now: Date) -> Decision {
    let plugged = bat.pluggedIn
    let prefix = "Calibrating \(c.phase.step)/4: "
    switch c.phase {
    case .dischargeLow:
        return Decision(mode: .calibrating, inhibitCharging: true, disableAdapter: plugged, preventSleep: plugged,
                        reason: prefix + "discharging to \(Calibration.lowTarget)%")
    case .chargeFull:
        return Decision(mode: .calibrating, inhibitCharging: false, preventSleep: plugged,
                        reason: prefix + (plugged ? "charging to 100%" : "plug in to continue"))
    case .holdFull:
        let left = max(0, Int((Calibration.holdSeconds - now.timeIntervalSince(c.since)) / 60))
        return Decision(mode: .calibrating, inhibitCharging: false, preventSleep: plugged,
                        reason: prefix + "resting at 100% (\(left) min left)")
    case .dischargeToLimit:
        return Decision(mode: .calibrating, inhibitCharging: true, disableAdapter: plugged, preventSleep: plugged,
                        reason: prefix + "discharging to \(limit)%")
    }
}
