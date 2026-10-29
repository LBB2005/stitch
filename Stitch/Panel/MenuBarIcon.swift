import AppKit

/// The "two stacked pages" glyph, drawn in code so it stays crisp at any scale.
enum MenuBarIcon {
    /// Template image: the menu bar tints it for light, dark and highlighted states.
    static let normal: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            drawGlyph(color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Stitch"
        return image
    }()

    /// Files are being dragged over the icon: a white glyph on an accent-colored pill.
    static var dropTarget: NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { rect in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.current?.cgContext.translateBy(x: 5, y: 0)
            drawGlyph(color: .white)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Stitch, release to add files"
        return image
    }

    /// Back page peeking out above and to the right of a front page with a folded corner.
    static func drawGlyph(color: NSColor) {
        let line: CGFloat = 1.4
        let back = NSRect(x: 6.2, y: 4.8, width: 9.3, height: 11.7)
        let front = NSRect(x: 2.5, y: 1.5, width: 9.3, height: 11.7)
        let fold: CGFloat = 3.2

        // Back page, with the part behind the front page cut away.
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
        clip.append(NSBezierPath(rect: front.insetBy(dx: -line * 1.1, dy: -line * 1.1)).reversed)
        clip.addClip()
        color.setStroke()
        let backPath = NSBezierPath(roundedRect: back, xRadius: 1.6, yRadius: 1.6)
        backPath.lineWidth = line
        backPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Front page with a dog-ear in the top-right corner.
        let page = NSBezierPath()
        page.move(to: NSPoint(x: front.minX + 1.4, y: front.minY))
        page.line(to: NSPoint(x: front.maxX - 1.4, y: front.minY))
        page.curve(to: NSPoint(x: front.maxX, y: front.minY + 1.4),
                   controlPoint1: NSPoint(x: front.maxX - 0.6, y: front.minY),
                   controlPoint2: NSPoint(x: front.maxX, y: front.minY + 0.6))
        page.line(to: NSPoint(x: front.maxX, y: front.maxY - fold))
        page.line(to: NSPoint(x: front.maxX - fold, y: front.maxY))
        page.line(to: NSPoint(x: front.minX + 1.4, y: front.maxY))
        page.curve(to: NSPoint(x: front.minX, y: front.maxY - 1.4),
                   controlPoint1: NSPoint(x: front.minX + 0.6, y: front.maxY),
                   controlPoint2: NSPoint(x: front.minX, y: front.maxY - 0.6))
        page.line(to: NSPoint(x: front.minX, y: front.minY + 1.4))
        page.curve(to: NSPoint(x: front.minX + 1.4, y: front.minY),
                   controlPoint1: NSPoint(x: front.minX, y: front.minY + 0.6),
                   controlPoint2: NSPoint(x: front.minX + 0.6, y: front.minY))
        page.close()
        page.lineWidth = line
        page.lineJoinStyle = .round
        color.setStroke()
        page.stroke()

        let ear = NSBezierPath()
        ear.move(to: NSPoint(x: front.maxX - fold, y: front.maxY))
        ear.line(to: NSPoint(x: front.maxX - fold, y: front.maxY - fold))
        ear.line(to: NSPoint(x: front.maxX, y: front.maxY - fold))
        ear.lineWidth = line * 0.85
        ear.lineJoinStyle = .round
        ear.stroke()

        // A dashed "stitch" across the middle of the front page.
        let stitch = NSBezierPath()
        stitch.move(to: NSPoint(x: front.minX + 2.2, y: front.midY - 0.6))
        stitch.line(to: NSPoint(x: front.maxX - 2.2, y: front.midY - 0.6))
        stitch.lineWidth = 1.1
        stitch.lineCapStyle = .round
        stitch.setLineDash([1.2, 1.6], count: 2, phase: 0)
        stitch.stroke()
    }
}
