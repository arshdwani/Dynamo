import Charts
import SwiftUI

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.iconHidden {
                Notice(text: "Your menu bar icon is hidden behind the notch. ⌘-drag other icons off the "
                       + "menu bar to make room. Opening Dynamo again always shows this window.",
                       color: .orange)
            }
            Header()
            TabBar()
            Group {
                switch model.tab {
                case 1: HealthTab()
                case 2: HistoryTab()
                case 3: EnergyTab()
                default: ControlTab()
                }
            }
            .transition(.opacity)
            Footer()
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Header

struct Header: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let b = model.battery
        HStack(spacing: 14) {
            RingGauge(value: Double(b?.percent ?? 0) / 100,
                      marker: model.config.enabled && model.config.limit < 100 ? Double(model.config.limit) / 100 : nil,
                      color: model.stateColor, size: 84) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(b?.percent ?? 0)").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("%").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                    Image(systemName: model.stateSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(model.stateColor)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.stateTitle).font(.title3.weight(.semibold))
                Text(model.stateDetail)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let b { PowerChips(battery: b) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct PowerChips: View {
    var battery: BatteryInfo

    var body: some View {
        HStack(spacing: 5) {
            if battery.pluggedIn {
                if let w = battery.adapterInputWatts, w > 0.1 {
                    Chip(icon: "powerplug.fill", text: watts(w) + " in")
                } else if let w = battery.adapterWatts {
                    Chip(icon: "powerplug.fill", text: "\(w) W")
                }
            }
            if let w = battery.systemLoadWatts { Chip(icon: "laptopcomputer", text: watts(w)) }
            if battery.pluggedIn && abs(battery.batteryWatts) >= 0.1 {
                Chip(icon: battery.batteryWatts > 0 ? "arrow.up" : "arrow.down",
                     text: watts(abs(battery.batteryWatts)))
                    .help(battery.batteryWatts > 0 ? "Charging the battery" : "Drawing from the battery")
            }
        }
    }
}

func watts(_ w: Double) -> String { String(format: w < 10 ? "%.1f W" : "%.0f W", w) }

struct RingGauge<Center: View>: View {
    var value: Double
    var marker: Double?
    var color: Color
    var size: CGFloat
    var lineWidth: CGFloat = 9
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, min(1, value)))
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, value))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let marker {
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 3, height: lineWidth + 5)
                    .offset(y: -(size - lineWidth) / 2)
                    .rotationEffect(.degrees(360 * marker))
                    .help("Charge limit")
            }
            center
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.6), value: value)
    }
}

struct Chip: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

// MARK: - Tabs

struct TabBar: View {
    @EnvironmentObject var model: Model

    private let tabs: [(id: Int, title: String, icon: String)] = [
        (0, "Control", "slider.horizontal.3"),
        (3, "Energy", "bolt.circle"),
        (1, "Health", "heart.text.square"),
        (2, "History", "chart.xyaxis.line"),
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tabs, id: \.id) { t in
                let selected = model.tab == t.id
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.tab = t.id }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .semibold))
                        Text(t.title).font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Building blocks

struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                HStack {
                    Label(title, systemImage: icon ?? "circle")
                        .font(.callout.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = EmptyView()
        self.content = content()
    }
}

struct Notice: View {
    var text: String
    var color: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Row: View {
    var key: String
    var value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}

struct Meter: View {
    var value: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct Tile: View {
    var title: String
    var value: String
    var detail: String
    var icon: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingToggle: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            SettingLabel(title: title, detail: detail)
            Spacer(minLength: 8)
            PillSwitch(isOn: $isOn)
        }
    }
}

struct SettingLabel: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// The app's own switch, in its accent color. (System switches turn grey whenever
/// the popover isn't the focused window.)
struct PillSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing))
                       : AnyShapeStyle(Color.primary.opacity(0.16)))
            .frame(width: 32, height: 19)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { isOn.toggle() } }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAction { if isEnabled { isOn.toggle() } }
    }
}

/// Charge-limit slider (20–100%) with a green→cyan fill like the header ring.
struct LimitSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let knob: CGFloat = 20
    private let range = 20.0...100.0

    var body: some View {
        GeometryReader { geo in
            let track = max(1, geo.size.width - knob)
            let x = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * track
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: track, height: 6)
                    .offset(x: knob / 2)
                Capsule().fill(LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, x), height: 6)
                    .offset(x: knob / 2)
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in onChange(snap(g.location.x, track)) }
                .onEnded { g in onCommit(snap(g.location.x, track)) })
        }
        .frame(height: knob)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Charge limit")
        .accessibilityValue("\(Int(value)) percent")
        .accessibilityAdjustableAction { dir in
            let step = dir == .increment ? 5.0 : -5.0
            onCommit(min(range.upperBound, max(range.lowerBound, value + step)))
        }
    }

    private func snap(_ x: CGFloat, _ track: CGFloat) -> Double {
        let f = Double(min(max(0, (x - knob / 2) / track), 1))
        return (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
    }
}

// MARK: - Control

struct ControlTab: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.installed {
                Notice(text: "Not installed yet. Run ./install.sh in the Dynamo folder.", color: .orange)
            } else if !model.daemonRunning {
                Notice(text: "The background service isn't running. Re-run ./install.sh.", color: .orange)
            } else if let err = model.status?.error {
                Notice(text: err, color: .red)
            }
            if let err = model.saveError { Notice(text: err, color: .red) }

            LimitCard()
            TasksCard()
            PowerCard()
            SettingsCard()
        }
    }
}

struct LimitCard: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let cfg = model.config
        let shown = Int(model.draftLimit ?? Double(cfg.limit))
        let enabled = Binding(get: { model.config.enabled }, set: { v in model.update { $0.enabled = v } })
        Card(title: "Charge Limit", icon: "battery.75percent") {
            PillSwitch(isOn: enabled)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(shown)%").font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(shown >= 100 ? "Charges fully" : "Resumes below \(shown - cfg.sailing)%")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LimitSlider(value: model.draftLimit ?? Double(cfg.limit)) { v in
                    model.draftLimit = v
                } onCommit: { v in
                    model.update { $0.limit = Int(v) }
                    model.draftLimit = nil
                }
                HStack(spacing: 6) {
                    ForEach([50, 60, 70, 80, 90, 100], id: \.self) { v in
                        Button("\(v)") { model.update { $0.limit = v } }
                            .buttonStyle(PillStyle(selected: cfg.limit == v))
                    }
                }
            }
            .disabled(!cfg.enabled)
            .opacity(cfg.enabled ? 1 : 0.45)
        }
    }
}

struct PillStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold)).monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(selected ? Color.cyan.opacity(0.3) : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.cyan : .clear, lineWidth: 1))
            .foregroundStyle(.primary)
            .contentShape(Capsule())
    }
}

struct TasksCard: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let cfg = model.config
        let usable = cfg.enabled && model.daemonRunning
        Card(title: "Tasks", icon: "wand.and.stars") {
            HStack(spacing: 8) {
                TaskTile(icon: "bolt.fill", title: "Top Up", subtitle: cfg.topUp ? "Stop" : "to 100%",
                         color: .green, active: cfg.topUp) { model.toggleTopUp() }
                    .help("Charge to 100% once, then go back to the limit")
                TaskTile(icon: "arrow.down.circle.fill", title: "Discharge",
                         subtitle: cfg.discharge ? "Stop" : "to \(cfg.limit)%",
                         color: .orange, active: cfg.discharge) { model.toggleDischarge() }
                    .disabled(cfg.limit >= 100 && !cfg.discharge)
                    .help("Run from the battery while plugged in until it reaches the limit")
                TaskTile(icon: "arrow.triangle.2.circlepath", title: "Calibrate",
                         subtitle: cfg.calibrate ? "Stop" : "full cycle",
                         color: .purple, active: cfg.calibrate) {
                    if cfg.calibrate || confirmCalibration(limit: cfg.limit) { model.toggleCalibration() }
                }
                .help("Recalibrate the battery gauge: 15% → 100% → rest 1 h → limit")
            }
            .disabled(!usable)
            .opacity(usable ? 1 : 0.45)

            if cfg.calibrate, let cal = model.status?.calibration {
                CalibrationProgress(calibration: cal, reason: model.status?.reason ?? "")
            } else if (cfg.topUp || cfg.discharge), let reason = model.status?.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func confirmCalibration(limit: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Calibrate the battery?"
        alert.informativeText = "Dynamo will run the battery down to 15%, charge it to 100%, let it rest "
            + "for an hour, then bring it back to \(limit)%. This takes several hours. Keep the Mac plugged in; "
            + "it will stay awake while calibrating."
        alert.addButton(withTitle: "Start Calibration")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct TaskTile: View {
    var icon: String
    var title: String
    var subtitle: String
    var color: Color
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(active ? color : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? color.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? color.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct CalibrationProgress: View {
    var calibration: Calibration
    var reason: String

    private let steps = ["Drain", "Charge", "Rest", "Return"]

    var body: some View {
        let current = calibration.phase.step
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(1...4, id: \.self) { i in
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().fill(i < current ? Color.purple : i == current ? Color.purple.opacity(0.25) : Color.primary.opacity(0.08))
                            if i < current {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(i)").font(.caption2.weight(.bold)).foregroundStyle(i == current ? Color.purple : .secondary)
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(steps[i - 1]).font(.caption2).foregroundStyle(i == current ? .primary : .secondary)
                    }
                    if i < 4 {
                        Capsule().fill(i < current ? Color.purple : Color.primary.opacity(0.1))
                            .frame(height: 2).padding(.bottom, 14)
                    }
                }
            }
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

struct PowerCard: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let apps = model.significantEnergyApps
        Card(title: "Power", icon: "leaf.fill") {
            HStack {
                Text("Low Power Mode")
                if model.lowPowerActive {
                    Text("ON").font(.caption2.weight(.bold)).foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.yellow, in: Capsule())
                }
                Spacer()
                Picker("", selection: Binding(get: { model.lowPowerMode ?? .never },
                                              set: { model.setLowPowerMode($0) })) {
                    ForEach(LowPowerMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.daemonRunning)
            }
            Divider()
            HStack {
                Text(apps.isEmpty ? "No Apps Using Significant Energy" : "Using Significant Energy")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Details") { withAnimation { model.tab = 3 } }
                    .buttonStyle(.link).font(.caption)
            }
            ForEach(apps.prefix(4)) { AppEnergyRow(app: $0, maxWatts: apps.first?.watts ?? 1, compact: true) }
        }
    }
}

struct SettingsCard: View {
    @EnvironmentObject var model: Model
    @AppStorage("settingsOpen") private var open = false
    @AppStorage("showPercent") private var showPercent = true
    @AppStorage("notifications") private var notifications = true

    var body: some View {
        let cfg = model.config
        Card {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SettingLabel(title: "Sailing range: \(cfg.sailing)%",
                                     detail: "Avoids topping up after every small drop")
                        Spacer(minLength: 8)
                        Stepper("", value: Binding(get: { model.config.sailing },
                                                   set: { v in model.update { $0.sailing = v } }),
                                in: 0...30)
                            .labelsHidden()
                    }
                    SettingToggle(title: "Pause charging when hot",
                                  detail: "Heat ages batteries faster than anything else",
                                  isOn: Binding(get: { model.config.heatProtection },
                                                set: { v in model.update { $0.heatProtection = v } }))
                    if cfg.heatProtection {
                        HStack {
                            SettingLabel(title: "Pause above \(Int(cfg.heatMaxC)) °C", detail: nil)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Stepper("", value: Binding(get: { model.config.heatMaxC },
                                                       set: { v in model.update { $0.heatMaxC = v } }),
                                    in: 25...60)
                                .labelsHidden()
                        }
                        .padding(.leading, 12)
                    }
                    SettingToggle(title: "Stay awake while charging to the limit",
                                  detail: "Charging stops while the Mac sleeps",
                                  isOn: Binding(get: { model.config.preventSleepWhileCharging },
                                                set: { v in model.update { $0.preventSleepWhileCharging = v } }))
                    if ChargeControl.hasLED {
                        SettingToggle(title: "Green MagSafe light at the limit", detail: nil,
                                      isOn: Binding(get: { model.config.magsafeLED },
                                                    set: { v in model.update { $0.magsafeLED = v } }))
                    }
                    Divider()
                    SettingToggle(title: "Show percentage in menu bar", detail: nil, isOn: $showPercent)
                    SettingToggle(title: "Notify when tasks finish", detail: nil, isOn: $notifications)
                    SettingToggle(title: "Launch at login", detail: nil,
                                  isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                .padding(.top, 8)
            } label: {
                Label("Settings", systemImage: "gearshape").font(.callout.weight(.semibold))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { open.toggle() } }
            }
        }
    }
}

// MARK: - Energy

struct EnergyTab: View {
    @EnvironmentObject var model: Model

    var body: some View {
        let apps = Array(model.energyApps.prefix(10))
        let total = model.energyApps.reduce(0) { $0 + $1.watts }
        VStack(alignment: .leading, spacing: 10) {
            if let b = model.battery { PowerFlowCard(battery: b, adapterDisabled: model.status?.adapterDisabled == true) }

            Card(title: "Apps", icon: "square.stack.3d.up.fill") {
                Text("CPU + GPU \(watts(total))").font(.caption).foregroundStyle(.secondary)
            } content: {
                if apps.isEmpty {
                    Text("Measuring…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(apps) { AppEnergyRow(app: $0, maxWatts: apps.first?.watts ?? 1) }
                }
            }
            Text("Averaged over ~30 s. Apps above \(String(format: "%.1f", EnergyMonitor.significantWatts)) W count "
                 + "as using significant energy. The rest of the Mac's power goes to the display, memory and the system.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PowerFlowCard: View {
    var battery: BatteryInfo
    var adapterDisabled: Bool

    var body: some View {
        let b = battery
        let batW = b.batteryWatts
        // Older firmware doesn't report input power; the Mac's draw is a fair stand-in.
        let adapterIn = b.adapterInputWatts ?? b.systemLoadWatts ?? 0
        let adapterActive = b.pluggedIn && !adapterDisabled && adapterIn > 0.2
        let batteryActive = abs(batW) >= 0.2
        Card(title: "Power Flow", icon: "point.3.connected.trianglepath.dotted") {
            HStack(spacing: 0) {
                FlowNode(icon: "powerplug.fill", title: "Adapter",
                         value: b.pluggedIn ? (adapterDisabled ? "Paused" : watts(adapterIn)) : "—",
                         color: .green, active: adapterActive)
                FlowArrow(active: adapterActive, forward: true, color: .green)
                FlowNode(icon: "laptopcomputer", title: "Mac", value: b.systemLoadWatts.map(watts) ?? "—",
                         color: .blue, active: true)
                FlowArrow(active: batteryActive, forward: batW > 0, color: batW > 0 ? .green : .orange)
                FlowNode(icon: "battery.75percent", title: "Battery",
                         value: batteryActive ? (batW > 0 ? "+" : "−") + watts(abs(batW)) : "Idle",
                         color: batW > 0 ? .green : .orange, active: batteryActive)
            }
            Text(explanation(adapterActive: adapterActive, batteryActive: batteryActive, batW: batW))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func explanation(adapterActive: Bool, batteryActive: Bool, batW: Double) -> String {
        if adapterDisabled && battery.pluggedIn { return "Adapter paused: the Mac is running from the battery to discharge it." }
        if !battery.pluggedIn { return "Running on battery." }
        if batW > 0.2 { return "The adapter powers the Mac and charges the battery." }
        if batW < -0.2 { return "The adapter can't keep up, so the battery is helping." }
        return "The adapter powers the Mac directly; the battery is resting."
    }
}

struct FlowNode: View {
    var icon: String
    var title: String
    var value: String
    var color: Color
    var active: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? color : .secondary)
                .frame(width: 40, height: 40)
                .background((active ? color : Color.primary).opacity(active ? 0.15 : 0.06), in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(width: 76)
    }
}

/// A dashed line whose dashes travel in the direction power flows.
struct FlowArrow: View {
    var active: Bool
    var forward: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 0.8) / 0.8) * 8
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 2, y: 6))
                    p.addLine(to: CGPoint(x: 30, y: 6))
                }
                .stroke(active ? color : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5],
                                           dashPhase: active ? (forward ? -phase : phase) : 0))
                Image(systemName: forward ? "chevron.right" : "chevron.left")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(active ? color : Color.secondary.opacity(0.3))
                    .offset(x: forward ? 13 : -13)
            }
            .frame(width: 32, height: 12)
        }
        .padding(.bottom, 30)
    }
}

struct AppEnergyRow: View {
    var app: AppEnergy
    var maxWatts: Double
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(for: app.bundlePath)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).lineLimit(1).truncationMode(.middle)
                if !compact {
                    Meter(value: app.watts / max(0.01, maxWatts),
                          color: app.watts >= EnergyMonitor.significantWatts ? .orange : .cyan, height: 4)
                }
            }
            Spacer(minLength: 6)
            if !compact {
                Text(String(format: "%.0f%%", app.cpuPercent))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                    .help("CPU (100% = one core)")
            }
            Text(String(format: app.watts < 0.1 ? "%.2f W" : "%.1f W", app.watts))
                .monospacedDigit()
                .foregroundStyle(app.watts >= EnergyMonitor.significantWatts ? .orange : .primary)
                .frame(width: 52, alignment: .trailing)
            if let running = AppIcons.runningApp(at: app.bundlePath) {
                Button { running.terminate() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit \(app.name)")
            } else {
                Color.clear.frame(width: 13, height: 1)
            }
        }
        .font(.callout)
    }
}

/// Icon lookups are slow-ish, so cache them per bundle.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let fallback: NSImage = {
        let img = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        img.isTemplate = true
        return img
    }()

    static func icon(for path: String?) -> NSImage {
        guard let path else { return fallback }
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }

    /// Regular apps can be asked to quit (they still get to save their work).
    static func runningApp(at path: String?) -> NSRunningApplication? {
        guard let path else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == path && $0.activationPolicy == .regular
        }
    }
}

// MARK: - Health

struct HealthTab: View {
    @EnvironmentObject var model: Model

    var body: some View {
        if let b = model.battery {
            let health = model.appleHealth?.maximumCapacity ?? b.rawHealthPercent
            let healthColor: Color = health >= 80 ? .green : health >= 70 ? .orange : .red
            let cycleUse = Double(b.cycleCount) / Double(max(1, b.designCycleCount))
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    HStack(spacing: 14) {
                        RingGauge(value: Double(health) / 100, marker: nil, color: healthColor, size: 70, lineWidth: 8) {
                            Text("\(health)%").font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Battery Health").font(.headline)
                            Text(model.appleHealth?.condition ?? (health >= 80 ? "Normal" : "Service Recommended"))
                                .font(.callout.weight(.semibold)).foregroundStyle(healthColor)
                            Text("Maximum capacity compared to when it was new")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Card(title: "Lifespan", icon: "hourglass") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Charge cycles")
                            Spacer()
                            Text("\(b.cycleCount) of \(b.designCycleCount)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        Meter(value: cycleUse, color: cycleUse < 0.8 ? .blue : .orange)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Full-charge capacity")
                            Spacer()
                            Text("\(b.maxCapacitymAh) of \(b.designCapacitymAh) mAh").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        Meter(value: Double(b.maxCapacitymAh) / Double(max(1, b.designCapacitymAh)), color: healthColor)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    Tile(title: "Temperature", value: String(format: "%.1f °C", b.temperatureC),
                         detail: b.temperatureC >= 40 ? "Hot" : b.temperatureC >= 35 ? "Warm" : "Normal",
                         icon: "thermometer.medium",
                         color: b.temperatureC >= 40 ? .red : b.temperatureC >= 35 ? .orange : .teal)
                    Tile(title: "Charge", value: "\(b.currentCapacitymAh) mAh",
                         detail: String(format: "%.2f V", b.voltage), icon: "bolt.batteryblock", color: .primary)
                }

                if !b.cellVoltages.isEmpty { CellsCard(battery: b) }

                Card(title: "Details", icon: "list.bullet") {
                    VStack(spacing: 5) {
                        if let m = b.minutesToFull, b.isCharging { Row("Time to full", hm(m)) }
                        if let m = b.minutesToEmpty { Row("Time remaining", hm(m)) }
                        if let w = b.adapterWatts {
                            Row("Adapter", "\(w) W" + (b.adapterName.map { " · \($0)" } ?? ""))
                        }
                        if let lo = b.dailyMinSoc, let hi = b.dailyMaxSoc { Row("Today's range", "\(lo)% – \(hi)%") }
                        if let lo = b.lifetimeMinTempC, let hi = b.lifetimeMaxTempC {
                            Row("Lifetime temperatures", "\(lo) – \(hi) °C")
                        }
                        Row("Cell disconnects", "\(b.cellDisconnects)")
                        if b.permanentFailure { Row("Status", "Permanent failure flagged ⚠︎") }
                        if let s = b.serial, !model.redacted { Row("Serial", s) }
                    }
                    .font(.callout)
                }
            }
        } else {
            Text("No battery found").foregroundStyle(.secondary)
        }
    }

    private func hm(_ m: Int) -> String { "\(m / 60)h \(m % 60)m" }
}

struct CellsCard: View {
    var battery: BatteryInfo

    var body: some View {
        let imbalance = battery.cellImbalancemV ?? 0
        Card(title: "Cells", icon: "square.grid.3x1.below.line.grid.1x2") {
            Text(imbalance <= 30 ? "Balanced · Δ \(imbalance) mV" : "Imbalanced · Δ \(imbalance) mV")
                .font(.caption).foregroundStyle(imbalance <= 30 ? Color.secondary : Color.orange)
        } content: {
            HStack(spacing: 10) {
                ForEach(Array(battery.cellVoltages.enumerated()), id: \.offset) { i, mv in
                    VStack(spacing: 4) {
                        // 3.0 V empty … 4.4 V full
                        Meter(value: (Double(mv) - 3000) / 1400, color: .green, height: 8)
                        Text(String(format: "%.3f V", Double(mv) / 1000)).font(.caption.monospacedDigit())
                        Text("Cell \(i + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - History

struct HistoryTab: View {
    @EnvironmentObject var model: Model
    @AppStorage("historyHours") private var hours = 24

    var body: some View {
        let windowStart = Date().addingTimeInterval(-Double(hours) * 3600)
        let samples = model.history.filter { $0.t >= windowStart }
        // Don't squash a short history into the right edge of a long window.
        let since = max(windowStart, samples.first?.t ?? windowStart)
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $hours) {
                Text("6 hours").tag(6)
                Text("24 hours").tag(24)
                Text("48 hours").tag(48)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if samples.count < 2 {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                        Text("History builds up as Dynamo runs, one sample every 5 minutes.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            } else {
                Card(title: "Charge", icon: "battery.75percent") {
                    ChargeChart(samples: samples, since: since,
                                limit: model.config.enabled && model.config.limit < 100 ? model.config.limit : nil)
                    HStack(spacing: 10) {
                        Legend(color: .green, text: "Charge")
                        Legend(color: .green.opacity(0.25), text: "Plugged in")
                        if model.config.enabled && model.config.limit < 100 {
                            Legend(color: .gray, text: "Limit", dashed: true)
                        }
                    }
                }
                Card(title: "Temperature", icon: "thermometer.medium") {
                    Chart(samples) { s in
                        LineMark(x: .value("Time", s.t), y: .value("°C", s.tempC))
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                    }
                    .chartXScale(domain: since...Date())
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartYScale(domain: tempDomain(samples))
                    .frame(height: 70)
                }
                let pcts = samples.map(\.pct)
                let temps = samples.map(\.tempC)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    Tile(title: "On power", value: "\(samples.filter(\.plugged).count * 100 / samples.count)%",
                         detail: "of the time", icon: "powerplug", color: .green)
                    Tile(title: "Range", value: "\(pcts.min() ?? 0)–\(pcts.max() ?? 0)%",
                         detail: "charge", icon: "arrow.up.and.down", color: .cyan)
                    Tile(title: "Avg temp", value: String(format: "%.0f°", temps.reduce(0, +) / Double(temps.count)),
                         detail: String(format: "max %.0f°", temps.max() ?? 0), icon: "thermometer.low", color: .orange)
                }
            }
        }
    }
}

/// At least a 4 °C span so sensor noise doesn't look like big swings.
func tempDomain(_ samples: [HistorySample]) -> ClosedRange<Double> {
    let lo = samples.map(\.tempC).min() ?? 25
    let hi = samples.map(\.tempC).max() ?? 35
    let mid = (lo + hi) / 2
    let half = max(2, (hi - lo) / 2 + 0.5)
    return (mid - half).rounded(.down)...(mid + half).rounded(.up)
}

struct ChargeChart: View {
    var samples: [HistorySample]
    var since: Date
    var limit: Int?

    /// Contiguous plugged-in stretches, for background shading.
    private var pluggedSpans: [(start: Date, end: Date)] {
        var spans: [(Date, Date)] = []
        var start: Date?
        for (i, s) in samples.enumerated() {
            if s.plugged, start == nil { start = s.t }
            let next = i + 1 < samples.count ? samples[i + 1] : nil
            if let st = start, !(next?.plugged ?? false) || next == nil {
                spans.append((st, next?.t ?? s.t))
                start = nil
            }
        }
        return spans
    }

    var body: some View {
        Chart {
            ForEach(Array(pluggedSpans.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end),
                              yStart: .value("Low", 0), yEnd: .value("High", 100))
                    .foregroundStyle(Color.green.opacity(0.1))
            }
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.t), y: .value("Charge", s.pct))
                    .foregroundStyle(LinearGradient(colors: [.green.opacity(0.35), .green.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.t), y: .value("Charge", s.pct))
                    .foregroundStyle(.green)
                    .interpolationMethod(.monotone)
            }
            if let limit {
                RuleMark(y: .value("Limit", limit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.gray)
            }
        }
        .chartXScale(domain: since...Date())
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in
            AxisGridLine()
            AxisValueLabel { if let i = v.as(Int.self) { Text("\(i)%") } }
        } }
        .frame(height: 130)
    }
}

struct Legend: View {
    var color: Color
    var text: String
    var dashed = false

    var body: some View {
        HStack(spacing: 4) {
            if dashed {
                Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 12, y: 4)) }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 12, height: 8)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            }
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @EnvironmentObject var model: Model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.daemonRunning ? Color.green : Color.red).frame(width: 7, height: 7)
            Text(model.daemonRunning ? "Service running" : "Service stopped")
                .font(.caption).foregroundStyle(.secondary)
            if model.status?.sleepPrevented == true {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Keeping the Mac awake until the target is reached")
            }
            Spacer()
            Button("Battery Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Open macOS Battery settings")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}
