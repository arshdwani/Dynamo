import Foundation

// Run with ./build.sh test — exercises decide() without touching the SMC.
var failures = 0
func check(_ cond: Bool, _ name: String) {
    print((cond ? "ok   " : "FAIL ") + name)
    if !cond { failures += 1 }
}

/// A synthetic battery, so the tests run on any Mac (including CI without a battery).
func bat(_ pct: Int, plugged: Bool = true, temp: Double = 30) -> BatteryInfo {
    BatteryInfo(percent: pct, pluggedIn: plugged, isCharging: plugged && pct < 100, fullyCharged: pct >= 100,
                currentCapacitymAh: 40 * pct, minutesToFull: nil, minutesToEmpty: nil,
                cycleCount: 100, designCycleCount: 1000, maxCapacitymAh: 4000, nominalCapacitymAh: 4100,
                designCapacitymAh: 4500, cellDisconnects: 0, permanentFailure: false,
                temperatureC: temp, voltage: 12.4, amperage: 0, cellVoltages: [4100, 4100, 4100],
                systemLoadWatts: 8, adapterInputWatts: plugged ? 10 : nil, adapterWatts: plugged ? 30 : nil,
                adapterName: nil, chargerCurrent: nil, dailyMinSoc: nil, dailyMaxSoc: nil,
                lifetimeMaxTempC: nil, lifetimeMinTempC: nil, serial: nil, gaugeName: nil)
}
let paused = PolicyState(wasInhibited: true)
let charging = PolicyState(wasInhibited: false)

// Limit + sailing
let cfg = Config()  // limit 80, sailing 5
check(!decide(cfg, bat(50), charging).inhibitCharging, "charges below limit")
check(decide(cfg, bat(50), charging).preventSleep, "keeps awake while charging to limit")
check(decide(cfg, bat(80), charging).mode == .holding, "stops at limit")
check(decide(cfg, bat(85), charging).inhibitCharging, "stops above limit")
check(decide(cfg, bat(77), paused).mode == .sailing, "sailing: stays paused inside band")
check(!decide(cfg, bat(77), charging).inhibitCharging, "sailing: keeps charging inside band")
check(!decide(cfg, bat(75), paused).inhibitCharging, "sailing: resumes at limit-sailing")
check(!decide(cfg, bat(80, plugged: false), charging).preventSleep, "no sleep assertion on battery")
check(decide(cfg, bat(60, plugged: false), charging).mode == .onBattery, "reports on battery")

var off = cfg; off.enabled = false; off.topUp = true
let dOff = decide(off, bat(95), paused)
check(!dOff.inhibitCharging && dOff.mode == .off, "disabled hands charging to macOS")
check(dOff.finishTopUp, "disabling clears pending one-shot tasks")

var full = cfg; full.limit = 100
check(!decide(full, bat(99), paused).inhibitCharging, "limit 100 never inhibits")

// Top up / discharge
var top = cfg; top.topUp = true
check(!decide(top, bat(90), paused).inhibitCharging, "top up charges past limit")
let topDone = decide(top, bat(100), charging)
check(topDone.finishTopUp && topDone.inhibitCharging, "top up finishes at 100% and returns to limit")

var dis = cfg; dis.discharge = true
let d1 = decide(dis, bat(90), charging)
check(d1.disableAdapter && d1.inhibitCharging && d1.mode == .discharging, "discharge disables adapter above limit")
let d2 = decide(dis, bat(80), paused)
check(d2.finishDischarge && !d2.disableAdapter, "discharge finishes at limit")
check(!decide(dis, bat(90, plugged: false), charging).disableAdapter, "discharge idle on battery")
var disFull = cfg; disFull.discharge = true; disFull.limit = 100
check(decide(disFull, bat(90), charging).finishDischarge, "discharge to 100% finishes at once")

// Heat protection with hysteresis
var heat = cfg; heat.heatProtection = true; heat.heatMaxC = 35
let hot = decide(heat, bat(50, temp: 35.5), charging)
check(hot.inhibitCharging && hot.mode == .heatPaused && hot.next.heatPaused, "heat protection pauses charging")
check(decide(heat, bat(50, temp: 34), hot.next).inhibitCharging, "heat: stays paused until 2°C below")
check(!decide(heat, bat(50, temp: 32.9), hot.next).inhibitCharging, "heat: resumes once cooled")
check(!decide(heat, bat(50, temp: 34), charging).inhibitCharging, "heat: cool battery charges")

// MagSafe LED
check(decide(cfg, bat(80), charging).greenLED, "LED green while holding")
check(decide(cfg, bat(77), paused).greenLED, "LED green while sailing")
check(!decide(cfg, bat(60), charging).greenLED, "LED left to macOS while charging")
var noLed = cfg; noLed.magsafeLED = false
check(!decide(noLed, bat(80), charging).greenLED, "LED option off")

// Calibration
var cal = cfg; cal.calibrate = true
let t0 = Date()
let c1 = decide(cal, bat(60), charging, now: t0)
check(c1.next.calibration?.phase == .dischargeLow && c1.disableAdapter && c1.preventSleep, "calibration 1: discharges")
let c2 = decide(cal, bat(15), c1.next, now: t0 + 100)
check(c2.next.calibration?.phase == .chargeFull && !c2.inhibitCharging && !c2.disableAdapter, "calibration 2: charges")
let c2b = decide(cal, bat(50), c2.next, now: t0 + 200)
check(c2b.next.calibration?.phase == .chargeFull && !c2b.inhibitCharging, "calibration 2: charges past the limit")
let c3 = decide(cal, bat(100), c2b.next, now: t0 + 300)
check(c3.next.calibration?.phase == .holdFull && !c3.inhibitCharging, "calibration 3: rests at 100%")
let c3b = decide(cal, bat(100), c3.next, now: t0 + 300 + 1800)
check(c3b.next.calibration?.phase == .holdFull, "calibration 3: holds for an hour")
let c3u = decide(cal, bat(99, plugged: false), c3.next, now: t0 + 600)
check(c3u.next.calibration?.phase == .chargeFull, "calibration 3: unplugging restarts the full charge")
let c4 = decide(cal, bat(100), c3.next, now: t0 + 300 + 3601)
check(c4.next.calibration?.phase == .dischargeToLimit && c4.disableAdapter, "calibration 4: discharges to limit")
let c5 = decide(cal, bat(80), c4.next, now: t0 + 9000)
check(c5.finishCalibration && c5.next.calibration == nil && c5.mode == .holding, "calibration finishes at limit")
let cLow = decide(cal, bat(10), charging, now: t0)
check(cLow.next.calibration?.phase == .chargeFull, "calibration starting below 15% skips to charging")
var calTop = cal; calTop.topUp = true
check(decide(calTop, bat(60), charging).finishTopUp, "calibration supersedes top up")

// Config compatibility and sanitizing
let oldJSON = #"{"enabled":true,"limit":70,"sailing":5,"topUp":false,"discharge":false,"heatProtection":false,"heatMaxC":35,"preventSleepWhileCharging":true}"#
let old = try? JSONDecoder().decode(Config.self, from: Data(oldJSON.utf8))
check(old?.limit == 70 && old?.magsafeLED == true && old?.calibrate == false, "loads config from older version")
check((try? JSONDecoder().decode(Config.self, from: Data("{}".utf8)))?.limit == 80, "empty config gets defaults")
check((try? JSONDecoder().decode(Config.self, from: Data(#"{"limit":70,"lowPowerRequest":"bogus"}"#.utf8)))?.limit == 70,
      "unknown low power value doesn't break the config")
var weird = Config(); weird.limit = 20; weird.sailing = 30
check(weird.sanitized.sailing == 10, "sailing can't push resume point below 10%")

// Update version comparison
check(isNewerVersion("1.10", than: "1.9"), "1.10 is newer than 1.9")
check(isNewerVersion("1.2", than: "1.1.9"), "1.2 is newer than 1.1.9")
check(!isNewerVersion("1.2", than: "1.2.0"), "1.2 equals 1.2.0")
check(!isNewerVersion("1.1", than: "1.2"), "1.1 is older than 1.2")

// History
var hist: [HistorySample] = []
let h0 = Date()
check(History.record(bat(50), into: &hist, now: h0), "history records first sample")
check(!History.record(bat(50), into: &hist, now: h0 + 60), "history skips samples within 5 min")
check(History.record(bat(50), into: &hist, now: h0 + 49 * 3600) && hist.count == 1, "history trims >48h")

// The essentials-only read must see the same battery as the full one (skipped without a battery, as on CI).
if let full = BatteryInfo.read(), let light = BatteryInfo.read(essentialsOnly: true) {
    check(light.percent == full.percent && light.pluggedIn == full.pluggedIn && light.isCharging == full.isCharging
          && light.fullyCharged == full.fullyCharged && abs(light.temperatureC - full.temperatureC) < 1
          && abs(light.voltage - full.voltage) < 0.2 && light.percent > 0 && light.voltage > 0,
          "essentials-only battery read matches the full read")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
