import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct DynamoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the status item directly (rather than MenuBarExtra) so we can draw our own
/// battery icon and tell when macOS has hidden it behind the notch or an
/// overcrowded menu bar, and fall back to a regular window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let model = Model()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var lastIconKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Dynamo"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageTrailing  // "80% ▭" like the system battery item

        popover.contentViewController = hosting()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        updateButton()

        firstLaunchSetup()

        // Give the menu bar a moment to lay the item out before checking it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.model.iconHidden = !self.statusItemVisible
            if self.model.iconHidden { self.showWindow() }
        }
    }

    /// Launching the app again (Spotlight, Finder, Launchpad) opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.iconHidden = !statusItemVisible
        showWindow()
        return false
    }

    /// It replaces the system battery item, so it should start with the Mac.
    private func firstLaunchSetup() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "didFirstLaunch") {
            d.set(true, forKey: "didFirstLaunch")
            if SMAppService.mainApp.status != .enabled { model.setLaunchAtLogin(true) }
        }
        if d.object(forKey: "notifications") as? Bool ?? true {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func hosting() -> NSViewController {
        let host = NSHostingController(rootView: PanelView().environmentObject(model))
        host.sizingOptions = .preferredContentSize
        return host
    }

    private func updateButton() {
        guard let button = item?.button else { return }
        let b = model.battery
        let pct = b?.percent ?? 0
        let badge: MenuBarIcon.Badge
        if model.status?.adapterDisabled == true && model.daemonRunning {
            badge = .down
        } else if b?.isCharging == true {
            badge = .bolt
        } else if b?.pluggedIn == true {
            badge = .plug
        } else {
            badge = .none
        }
        // Same cues as the system icon: yellow in Low Power Mode, red when nearly empty.
        let low = pct <= 10 && b?.pluggedIn == false
        let fill: NSColor? = low ? .systemRed : model.lowPowerActive ? .systemYellow : nil
        let showPercent = UserDefaults.standard.object(forKey: "showPercent") as? Bool ?? true

        button.toolTip = "\(model.stateTitle): \(model.stateDetail)"
        // Redraw only when something visible changed.
        let key = "\(pct)|\(badge)|\(String(describing: fill))|\(showPercent)"
        guard key != lastIconKey else { return }
        lastIconKey = key

        button.image = MenuBarIcon.make(percent: pct, badge: badge, fill: fill)
        button.title = showPercent ? "\(pct)% " : ""
        button.font = .menuBarFont(ofSize: 0)
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.panelVisible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: hosting())
            w.title = "Dynamo"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.panelVisible = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) { updatePanelVisible() }
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.updatePanelVisible() }
    }

    private func updatePanelVisible() {
        model.panelVisible = popover.isShown || window?.isVisible == true
    }

    /// False when the item sits in the notch gap or off-screen, which is where
    /// macOS puts status items that don't fit.
    private var statusItemVisible: Bool {
        guard let w = item.button?.window, let screen = w.screen ?? NSScreen.main else { return false }
        let f = w.frame
        if f.width < 1 || !screen.frame.intersects(f) { return false }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = (left.maxX + screen.frame.minX)...(right.minX + screen.frame.minX)
            if notch.contains(f.minX) || notch.contains(f.maxX) { return false }
        }
        return true
    }
}
