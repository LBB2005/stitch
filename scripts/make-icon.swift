// Draws the app icon (two stacked pages joined by a stitch on a blue squircle) into AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "Stitch/Resources/Assets.xcassets/AppIcon.appiconset")

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024

    // Squircle background, inset like macOS icons (824 of 1024).
    let bg = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: bg, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.0, green: 0.36, blue: 0.92, alpha: 1))!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func page(_ rect: NSRect, alpha: CGFloat, fold: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.22)
        sh.shadowBlurRadius = 18 * u
        sh.shadowOffset = NSSize(width: 0, height: -8 * u)
        sh.set()
        let r = 22 * u, f = 92 * u
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.minX + r, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 0)
        if fold {
            p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - f))
            p.line(to: NSPoint(x: rect.maxX - f, y: rect.maxY))
        } else {
            p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
            p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        }
        p.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
        p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        p.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
        if fold {
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: rect.maxX - f, y: rect.maxY))
            ear.line(to: NSPoint(x: rect.maxX - f, y: rect.maxY - f + 14 * u))
            ear.appendArc(withCenter: NSPoint(x: rect.maxX - f + 14 * u, y: rect.maxY - f + 14 * u), radius: 14 * u,
                          startAngle: 180, endAngle: 270)
            ear.line(to: NSPoint(x: rect.maxX, y: rect.maxY - f))
            ear.close()
            NSColor(srgbRed: 0.80, green: 0.87, blue: 0.97, alpha: 1).setFill()
            ear.fill()
        }
    }

    page(NSRect(x: 400 * u, y: 330 * u, width: 360 * u, height: 470 * u), alpha: 0.72, fold: false)
    let front = NSRect(x: 264 * u, y: 224 * u, width: 360 * u, height: 470 * u)
    page(front, alpha: 1, fold: true)

    // Text lines on the front page.
    NSColor(srgbRed: 0.75, green: 0.80, blue: 0.88, alpha: 1).setFill()
    for (i, w) in [0.62, 0.72, 0.5].enumerated() {
        let y = front.maxY - 150 * u - CGFloat(i) * 46 * u
        NSBezierPath(roundedRect: NSRect(x: front.minX + 52 * u, y: y, width: (front.width - 104 * u) * w, height: 18 * u),
                     xRadius: 9 * u, yRadius: 9 * u).fill()
    }
    // The stitch: a dashed blue seam across the lower half.
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: front.minX + 52 * u, y: front.minY + 130 * u))
    seam.line(to: NSPoint(x: front.maxX - 52 * u, y: front.minY + 130 * u))
    seam.lineWidth = 22 * u
    seam.lineCapStyle = .round
    seam.setLineDash([26 * u, 34 * u], count: 2, phase: 0)
    NSColor(srgbRed: 0.0, green: 0.42, blue: 0.95, alpha: 1).setStroke()
    seam.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! draw(px).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes")
