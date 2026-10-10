import AppKit
import SwiftUI

// Renders the panel's tabs to PNGs (light + dark) for visual checks:
//   ./build.sh snapshot  ->  build/snapshots/*.png
let out = CommandLine.arguments.dropFirst().first ?? "build/snapshots"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let app = NSApplication.shared
// Controls only draw in their active (colored) state in the key window of the
// active app, so the tool briefly becomes a background app and takes focus.
app.setActivationPolicy(.accessory)

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Opaque stand-ins for the popover's material, which renders as flat grey offscreen.
func background(_ appearance: NSAppearance.Name) -> NSColor {
    appearance == .darkAqua ? NSColor(srgbRed: 0.155, green: 0.155, blue: 0.165, alpha: 1)
                            : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1)
}

MainActor.assumeIsolated {
    let model = Model()
    model.redacted = true
    model.panelVisible = true
    RunLoop.main.run(until: Date().addingTimeInterval(3.2))
    model.refresh()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))

    // Freeze the energy list and drop this tool and the helpers it launched.
    model.panelVisible = false
    model.energyApps.removeAll { ["snapshot", "pmset", "system_profiler", "ChargeLimit"].contains($0.name) }

    // Before the first install under the Dynamo name, history still lives in the old folder.
    if model.history.count < 2,
       let data = FileManager.default.contents(atPath: "/Library/Application Support/ChargeLimit/history.json") {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        model.history = (try? dec.decode([HistorySample].self, from: data)) ?? []
    }

    // If the service isn't installed on this machine, show the panel as it looks
    // with it running (real battery data, default settings).
    if !model.daemonRunning, let b = model.battery {
        model.frozen = true
        model.installed = true
        model.lowPowerMode = model.lowPowerMode ?? .never
        let mode: ChargeMode = !b.pluggedIn ? .onBattery : b.percent >= model.config.limit ? .holding : .charging
        model.status = DaemonStatus(updatedAt: Date(), mode: mode, chargingInhibited: mode == .holding,
                                    adapterDisabled: false, sleepPrevented: false,
                                    reason: decide(model.config, b, PolicyState()).reason)
    }

    // SNAPSHOT_UPDATE=1 shows the update banner.
    model.availableUpdate = ProcessInfo.processInfo.environment["SNAPSHOT_UPDATE"] == nil ? nil
        : Release(version: "1.3", url: URL(string: "https://github.com/\(Updater.repo)/releases")!)
    NSApp.activate(ignoringOtherApps: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for (tab, tabName) in [(0, "control"), (3, "energy"), (1, "health"), (2, "history")] {
            model.tab = tab
            let host = NSHostingView(rootView: PanelView().environmentObject(model)
                .environment(\.controlActiveState, .key))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            // Far off-screen, but ordered in and key so controls render as active.
            let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            let bg = NSView(frame: NSRect(origin: .zero, size: size))
            bg.wantsLayer = true
            bg.appearance = NSAppearance(named: appearance)
            bg.layer?.backgroundColor = background(appearance).cgColor
            host.frame = bg.bounds
            bg.addSubview(host)
            window.contentView = bg
            window.orderFrontRegardless()
            window.makeKey()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { continue }
            bg.cacheDisplay(in: bg.bounds, to: rep)
            let path = "\(out)/\(tabName)-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // 3x render for large-format images (Tools/make-social-images.swift).
            let big = ImageRenderer(content: PanelView().environmentObject(model)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .background(Color(nsColor: background(appearance))))
            big.scale = 3
            if let cg = big.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(out)/\(tabName)-\(name)@3x.png"))
            }
            print(path, Int(size.width), "x", Int(size.height))
            window.orderOut(nil)
        }
    }
    // Menu bar icon variants.
    let variants: [(String, Int, MenuBarIcon.Badge, NSColor?)] = [
        ("icon-80-plug", 80, .plug, nil), ("icon-45-bolt", 45, .bolt, nil),
        ("icon-62-none", 62, .none, nil), ("icon-8-low", 8, .none, .systemRed),
        ("icon-55-lpm", 55, .none, .systemYellow), ("icon-90-down", 90, .down, nil),
    ]
    for (name, pct, badge, fill) in variants {
        let img = MenuBarIcon.make(percent: pct, badge: badge, fill: fill)
        let scale: CGFloat = 8
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(27 * scale), pixelsHigh: Int(13 * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 27 * scale, height: 13 * scale).fill()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            img.draw(in: NSRect(x: 0, y: 0, width: 27 * scale, height: 13 * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
