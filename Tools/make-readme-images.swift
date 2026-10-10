import AppKit

// Builds docs/screenshots.png and docs/social-preview.png from build/snapshots.
//   ./build.sh snapshot && swift Tools/make-readme-images.swift
let bg = NSGradient(colors: [NSColor(red: 0.10, green: 0.20, blue: 0.24, alpha: 1),
                             NSColor(red: 0.03, green: 0.08, blue: 0.11, alpha: 1)])!

func canvas(_ w: Int, _ h: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func panel(_ rep: NSImageRep, in rect: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    rep.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

func load(_ name: String) -> NSImageRep {
    NSImage(contentsOfFile: "build/snapshots/\(name).png")!.representations.first!
}

// Four tabs side by side.
let tabs = ["control", "energy", "health", "history"].map { load("\($0)-dark") }
let pad = 60, gap = 40
let stripH = tabs.map(\.pixelsHigh).max()! + pad * 2
let stripW = tabs.reduce(0) { $0 + $1.pixelsWide } + gap * (tabs.count - 1) + pad * 2
let strip = canvas(stripW, stripH) { r in
    bg.draw(in: r, angle: -90)
    var x = pad
    for t in tabs {
        panel(t, in: NSRect(x: x, y: stripH - pad - t.pixelsHigh, width: t.pixelsWide, height: t.pixelsHigh), radius: 24)
        x += t.pixelsWide + gap
    }
}
try! strip.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/screenshots.png"))

// Social preview card (GitHub recommends 1280 × 640).
let control = load("control-dark")
let icon = NSImage(contentsOfFile: "docs/icon.png")!
let card = canvas(1280, 640) { r in
    bg.draw(in: r, angle: -90)
    icon.draw(in: NSRect(x: 80, y: 360, width: 150, height: 150))
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color]
        NSAttributedString(string: s, attributes: attrs).draw(at: NSPoint(x: 92, y: y))
    }
    text("Dynamo", 92, .bold, .white, 230)
    text("Battery care for Apple Silicon Macs", 32, .medium, NSColor(white: 0.85, alpha: 1), 180)
    text("Charge limit · Calibration · Health · Energy", 26, .regular,
         NSColor(red: 0.35, green: 0.92, blue: 1.0, alpha: 1), 128)
    text("Free & open source", 22, .regular, NSColor(white: 0.6, alpha: 1), 84)
    // Top of the control panel, peeking in from the right.
    let w: CGFloat = 400
    let h = w * CGFloat(control.pixelsHigh) / CGFloat(control.pixelsWide)
    panel(control, in: NSRect(x: 800, y: 640 - 60 - h, width: w, height: h), radius: 18)
}
try! card.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/social-preview.png"))
print("wrote docs/screenshots.png and docs/social-preview.png")
