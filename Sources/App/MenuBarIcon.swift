import AppKit

/// A battery glyph in the style of the system one: exact fill level, with a bolt
/// (charging), plug (on power, not charging) or arrow (forced discharge) cut into it.
enum MenuBarIcon {
    enum Badge { case none, bolt, plug, down }

    static func make(percent: Int, badge: Badge, fill: NSColor?) -> NSImage {
        let size = NSSize(width: 27, height: 13)
        // A drawing handler renders at display time, so labelColor follows the
        // menu bar's light/dark appearance even for non-template (colored) images.
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 0.5, width: 23.5, height: 12)
            let ink = NSColor.labelColor

            let outline = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
            ink.withAlphaComponent(0.45).setStroke()
            outline.lineWidth = 1
            outline.stroke()

            ink.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 25, y: 4.2, width: 1.8, height: 4.6), xRadius: 0.9, yRadius: 0.9).fill()

            let inner = body.insetBy(dx: 2, dy: 2)
            let level = max(0, min(100, percent))
            let bar = NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                                       width: level > 0 ? max(2, inner.width * CGFloat(level) / 100) : 0,
                                                       height: inner.height),
                                   xRadius: 1.8, yRadius: 1.8)
            if level > 0 {
                (fill ?? ink).setFill()
                bar.fill()
            }

            // Like the system icon: the glyph is cut out of the fill (see-through)
            // and drawn solid where it sits over the empty part. Parts are drawn one
            // by one so overlapping shapes don't cancel each other out.
            let parts = paths(for: badge, center: NSPoint(x: body.midX, y: body.midY))
            if !parts.isEmpty, let ctx = NSGraphicsContext.current {
                ctx.saveGraphicsState()
                bar.addClip()
                ctx.compositingOperation = .destinationOut
                NSColor.black.setFill()
                parts.forEach { $0.fill() }
                ctx.restoreGraphicsState()

                ctx.saveGraphicsState()
                let outside = NSBezierPath(rect: NSRect(origin: .zero, size: size))
                outside.append(bar)
                outside.windingRule = .evenOdd
                outside.addClip()
                ink.setFill()
                parts.forEach { $0.fill() }
                ctx.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = fill == nil
        image.accessibilityDescription = "Battery \(percent)%"
        return image
    }

    /// Glyphs drawn as paths around `c`, about 9 × 10 pt.
    private static func paths(for badge: Badge, center c: NSPoint) -> [NSBezierPath] {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c.x + x, y: c.y + y) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: c.x + x, y: c.y + y, width: w, height: h), xRadius: r, yRadius: r)
        }
        switch badge {
        case .none:
            return []
        case .bolt:
            let path = NSBezierPath()
            path.move(to: p(1.3, 5.3))
            path.line(to: p(-3.0, -0.3))
            path.line(to: p(-0.2, -0.3))
            path.line(to: p(-1.3, -5.3))
            path.line(to: p(3.0, 0.3))
            path.line(to: p(0.2, 0.3))
            path.close()
            return [path]
        case .plug:
            // Sideways plug: cord on the left, body, two prongs on the right.
            return [rect(-1.8, -2.8, 3.6, 5.6, r: 1.2),
                    rect(1.6, 0.9, 2.8, 1.1), rect(1.6, -2.0, 2.8, 1.1),
                    rect(-4.6, -0.6, 3.0, 1.2)]
        case .down:
            let head = NSBezierPath()
            head.move(to: p(-3.4, -0.3))
            head.line(to: p(3.4, -0.3))
            head.line(to: p(0, -5.0))
            head.close()
            return [rect(-0.8, -0.6, 1.6, 5.3), head]
        }
    }
}
