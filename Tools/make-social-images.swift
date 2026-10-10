import AppKit

// Builds a 4:5 portrait gallery (2160 × 2700) for Reddit / X / LinkedIn into
// docs/social/, from the 3x renders in build/snapshots.
//   ./build.sh snapshot && swift Tools/make-social-images.swift
let W = 2160, H = 2700
let slides: [(file: String, tab: String, title: String, subtitle: String)] = [
    ("1-dynamo", "control", "Dynamo", "Free, open-source battery care for Apple Silicon Macs"),
    ("2-energy", "energy", "See where your power goes", "Live power flow and the apps using the most energy"),
    ("3-health", "health", "Know your battery's health", "Health, cycles, temperature and every cell's voltage"),
    ("4-history", "history", "Track charge and heat", "Up to 48 hours of charge and temperature history"),
]
let bg = NSGradient(colors: [NSColor(red: 0.10, green: 0.20, blue: 0.24, alpha: 1),
                             NSColor(red: 0.03, green: 0.08, blue: 0.11, alpha: 1)])!
let cyan = NSColor(red: 0.35, green: 0.92, blue: 1.0, alpha: 1)

func centered(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: p]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 80, y: y, width: CGFloat(W - 160), height: size * 1.4))
}

try? FileManager.default.createDirectory(atPath: "docs/social", withIntermediateDirectories: true)
for slide in slides {
    guard let panel = NSImage(contentsOfFile: "build/snapshots/\(slide.tab)-dark@3x.png")?.representations.first
    else { fatalError("missing render for \(slide.tab); run ./build.sh snapshot") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    centered(slide.title, size: slide.tab == "control" ? 150 : 112, weight: .bold, color: .white, y: CGFloat(H) - 290)
    centered(slide.subtitle, size: 56, weight: .medium, color: NSColor(white: 0.82, alpha: 1), y: CGFloat(H) - 420)
    centered("github.com/arshdwani/Dynamo", size: 46, weight: .semibold, color: cyan, y: 70)

    // Panel: as large as fits between the captions, never enlarged past the 3x render.
    let maxH = CGFloat(H) - 500 - 190, maxW = CGFloat(W) - 300
    let scale = min(1.15, maxH / CGFloat(panel.pixelsHigh), maxW / CGFloat(panel.pixelsWide))
    let size = NSSize(width: CGFloat(panel.pixelsWide) * scale, height: CGFloat(panel.pixelsHigh) * scale)
    let rect = NSRect(x: (CGFloat(W) - size.width) / 2, y: 190 + (maxH - size.height) / 2,
                      width: size.width, height: size.height)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 60
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    panel.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shape.lineWidth = 3
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()

    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "docs/social/\(slide.file).png"))
    print("docs/social/\(slide.file).png  scale \(String(format: "%.2f", scale))")
}
