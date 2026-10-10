import AppKit

// Draws the app icon and writes Resources/AppIcon.icns.
//   swift Tools/make-icon.swift
func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Squircle body on Apple's 1024 grid (824 pt body, 100 pt margin) with a soft shadow.
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.10, green: 0.20, blue: 0.24, alpha: 1),
                        NSColor(red: 0.03, green: 0.08, blue: 0.11, alpha: 1)])!.draw(in: body, angle: -90)

    // Battery outline and tip.
    let shell = NSBezierPath(roundedRect: r(212, 372, 560, 280), xRadius: 64 * s, yRadius: 64 * s)
    shell.lineWidth = 30 * s
    NSColor.white.withAlphaComponent(0.92).setStroke()
    shell.stroke()
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: r(792, 462, 34, 100), xRadius: 17 * s, yRadius: 17 * s).fill()

    // Charge fill up to the 80% limit.
    let inner = r(252, 412, 480, 200)
    let fill = NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.8, height: inner.height),
                            xRadius: 34 * s, yRadius: 34 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 1),
                        NSColor(red: 0.15, green: 0.80, blue: 0.85, alpha: 1)])!.draw(in: fill, angle: 0)

    // Limit marker crossing the battery.
    let x = inner.minX + inner.width * 0.8 + 14 * s
    let marker = NSBezierPath(roundedRect: NSRect(x: x - 9 * s, y: 330 * s, width: 18 * s, height: 364 * s),
                              xRadius: 9 * s, yRadius: 9 * s)
    NSColor(red: 0.35, green: 0.92, blue: 1.0, alpha: 1).setFill()
    marker.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/icon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
