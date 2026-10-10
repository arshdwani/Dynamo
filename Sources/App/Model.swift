import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class Model: ObservableObject {
    @Published var battery: BatteryInfo?
    @Published var config = Config()
    @Published var status: DaemonStatus?
    @Published var history: [HistorySample] = []
    @Published var installed = false
    @Published var saveError: String?
    /// Slider value while dragging; saved to config on release.
    @Published var draftLimit: Double?
    @Published var appleHealth: AppleBatteryHealth?
    /// Set by AppDelegate when macOS hides the status item (notch / full menu bar).
    @Published var iconHidden = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var energyApps: [AppEnergy] = []
    /// Low Power Mode setting as pmset reports it, and whether it is in effect right now.
    @Published var lowPowerMode: LowPowerMode?
    @Published var lowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// What the Low Power Mode switch was just set to, until macOS catches up (~5 s).
    @Published private var lowPowerPending: Bool?
    private var lowPowerPendingAt = Date.distantPast
    /// A newer release on GitHub, if there is one.
    @Published var availableUpdate: Release?
    enum UpdateCheck { case idle, checking, upToDate, failed }
    /// Result of the last manual "Check for Updates".
    @Published var updateCheck = UpdateCheck.idle
    /// Energy sampling walks every process, so it only runs while someone is looking.
    var panelVisible = false {
        didSet { if panelVisible && !oldValue { refresh() } }
    }
    /// Hides identifying details (battery serial) for screenshots.
    var redacted = false
    /// Stops refreshing, so a screenshot can pin a state.
    var frozen = false
    @Published var tab = UserDefaults.standard.integer(forKey: "tab") {
        didSet { UserDefaults.standard.set(tab, forKey: "tab") }
    }

    private let energy = EnergyMonitor()
    private var timer: Timer?
    private var lastHistoryLoad = Date.distantPast
    private var lastHealthLoad = Date.distantPast
    private var lastLowPowerRead = Date.distantPast
    private var lowPowerRequestedAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init() {
        restoreKnownUpdate()
        refresh()
        _ = energy.sample()  // baseline, so the first look at the panel has real numbers
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lowPowerActive = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.lowPowerPending = nil
                self?.lastLowPowerRead = .distantPast
            }
        })
    }

    func refresh() {
        guard !frozen else { return }
        battery = BatteryInfo.read()
        status = DaemonStatus.load()
        if panelVisible { energyApps = energy.sample() }
        installed = Config.exists
        // A failed parse means the file is mid-write; keep the last good copy.
        if let c = Config.load(), c != config { config = c }

        if let s = status { notifyIfNeeded(s) }

        let now = Date()
        // pmset is a process launch, so read it rarely: every 30 s, or right after a change.
        if now.timeIntervalSince(lastLowPowerRead) > 30 && now.timeIntervalSince(lowPowerRequestedAt) > 6 {
            lastLowPowerRead = now
            Task.detached {
                let mode = LowPowerMode.current()
                await MainActor.run { self.lowPowerMode = mode }
            }
        }
        if now.timeIntervalSince(lastHealthLoad) > 600 {
            lastHealthLoad = now
            Task.detached {
                let h = AppleBatteryHealth.read()
                await MainActor.run { self.appleHealth = h }
            }
        }
        checkForUpdates()
        if now.timeIntervalSince(lastHistoryLoad) > 60 {
            history = History.load()
            lastHistoryLoad = now
        }
    }

    /// Automatic check: once a day (and at launch), unless turned off in Settings.
    func checkForUpdates(force: Bool = false) {
        let d = UserDefaults.standard
        guard d.object(forKey: "checkUpdates") as? Bool ?? true else { return }
        let last = d.double(forKey: "lastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > Updater.checkInterval else { return }
        runUpdateCheck(manual: false)
    }

    /// The "Check for Updates" button: always checks, and reports the result.
    func checkForUpdatesNow() {
        guard updateCheck != .checking else { return }
        runUpdateCheck(manual: true)
    }

    private func runUpdateCheck(manual: Bool) {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        if manual { updateCheck = .checking }
        Task {
            let r = await Updater.latestRelease()
            if let r {
                d.set(r.version, forKey: "latestVersion")
                d.set(r.url.absoluteString, forKey: "latestURL")
                self.availableUpdate = isNewerVersion(r.version, than: appVersion) ? r : nil
            }
            guard manual else { return }
            self.updateCheck = r == nil ? .failed : (self.availableUpdate == nil ? .upToDate : .idle)
            // Let the result linger briefly, then clear it.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.updateCheck != .checking { self.updateCheck = .idle }
        }
    }

    /// The last known newer release, so the banner survives relaunches between checks.
    private func restoreKnownUpdate() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "latestVersion"), let u = d.string(forKey: "latestURL").flatMap(URL.init(string:)),
           isNewerVersion(v, than: appVersion), d.object(forKey: "checkUpdates") as? Bool ?? true {
            availableUpdate = Release(version: v, url: u)
        }
    }

    /// Applies a change on top of the file's current contents, so a flag the daemon
    /// just cleared (top up finished, ...) isn't written back.
    func update(_ change: (inout Config) -> Void) {
        var c = Config.load() ?? config
        change(&c)
        c = c.sanitized
        config = c
        do {
            try c.save()
            saveError = nil
        } catch {
            saveError = "Can't save settings. Run install.sh first."
        }
    }

    /// The quick switch: on now (Always) or off (Never), like the system battery menu.
    var lowPowerSwitchOn: Bool {
        if let p = lowPowerPending, Date().timeIntervalSince(lowPowerPendingAt) < 15 { return p }
        return lowPowerActive
    }

    func setLowPowerNow(_ on: Bool) {
        lowPowerPending = on
        lowPowerPendingAt = Date()
        setLowPowerMode(on ? .always : .never)
    }

    func setLowPowerMode(_ mode: LowPowerMode) {
        lowPowerMode = mode
        lowPowerRequestedAt = Date()
        lastLowPowerRead = .distantPast
        update { $0.lowPowerRequest = mode }
    }

    /// One-shot tasks are mutually exclusive.
    func toggleTopUp() { update { $0.topUp.toggle(); $0.discharge = false; $0.calibrate = false } }
    func toggleDischarge() { update { $0.discharge.toggle(); $0.topUp = false; $0.calibrate = false } }
    func toggleCalibration() { update { $0.calibrate.toggle(); $0.topUp = false; $0.discharge = false } }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            saveError = "Launch at login failed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Notifications

    private func notifyIfNeeded(_ s: DaemonStatus) {
        guard let text = s.event, let at = s.eventAt else { return }
        let key = "lastEventAt"
        let seen = UserDefaults.standard.double(forKey: key)
        guard at.timeIntervalSince1970 > seen else { return }
        UserDefaults.standard.set(at.timeIntervalSince1970, forKey: key)
        // Only announce fresh events, not one found on launch.
        guard Date().timeIntervalSince(at) < 120,
              UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }

        let content = UNMutableNotificationContent()
        content.title = "Dynamo"
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Presentation

    var daemonRunning: Bool { status?.isFresh ?? false }

    var significantEnergyApps: [AppEnergy] {
        energyApps.filter { $0.watts >= EnergyMonitor.significantWatts }
    }

    /// The daemon's mode, or a best guess from the battery when it isn't running.
    var mode: ChargeMode {
        if daemonRunning, let m = status?.mode { return m }
        guard let b = battery else { return .noConfig }
        if !b.pluggedIn { return .onBattery }
        return b.isCharging ? .charging : .holding
    }

    var stateTitle: String {
        let b = battery
        switch mode {
        case .off, .noLimit, .noConfig:
            guard let b, b.pluggedIn else { return "On Battery" }
            return b.isCharging ? "Charging" : (b.percent >= 100 ? "Fully Charged" : "Not Charging")
        case .onBattery: return "On Battery"
        case .charging: return "Charging"
        case .holding: return "Limit Reached"
        case .sailing: return "Sailing"
        case .heatPaused: return "Cooling Down"
        case .topUp: return "Topping Up"
        case .discharging: return "Discharging"
        case .calibrating: return "Calibrating"
        }
    }

    var stateDetail: String {
        guard daemonRunning else {
            return installed ? "Background service isn't running" : "Run install.sh to finish setup"
        }
        let cfg = config
        switch mode {
        case .off: return "Limiting is off; macOS manages charging"
        case .noLimit:
            if let m = battery?.minutesToFull, battery?.isCharging == true { return "\(m / 60)h \(m % 60)m until full" }
            return "No limit set"
        case .onBattery:
            if let m = battery?.minutesToEmpty { return "\(m / 60)h \(m % 60)m remaining" }
            return cfg.enabled ? "Will charge to \(cfg.limit)% when plugged in" : "Calculating time remaining…"
        case .charging: return "Up to \(cfg.limit)%"
        case .holding: return "Charging paused at \(cfg.limit)%"
        case .sailing: return "Charging resumes below \(cfg.limit - cfg.sailing)%"
        case .heatPaused, .discharging, .calibrating, .topUp: return status?.reason ?? ""
        case .noConfig: return "Run install.sh to finish setup"
        }
    }

    var stateColor: Color {
        let pct = battery?.percent ?? 100
        switch mode {
        case .charging, .topUp: return .green
        case .holding, .sailing: return .cyan
        case .discharging: return .orange
        case .calibrating: return .purple
        case .heatPaused: return .red
        default:
            if lowPowerActive { return .yellow }
            return pct <= 10 ? .red : pct <= 20 ? .orange : .green
        }
    }

    var stateSymbol: String {
        switch mode {
        case .charging, .topUp: return "bolt.fill"
        case .holding, .sailing: return "pause.fill"
        case .discharging: return "arrow.down"
        case .calibrating: return "arrow.triangle.2.circlepath"
        case .heatPaused: return "thermometer.high"
        case .onBattery: return lowPowerActive ? "leaf.fill" : "battery.75percent"
        default: return battery?.isCharging == true ? "bolt.fill" : "powerplug.fill"
        }
    }
}
