import AppKit
import PDFKit

/// Draws one overlay in the viewer. Display only: the PDFKit document is never written, Save Copy
/// stamps the overlay with MuPDF instead, using the same drawing code.
final class OverlayAnnotation: PDFAnnotation {
    private(set) var overlay: Overlay
    /// While its text is being typed in the inline editor, only the box is drawn.
    var hidesText = false

    init(_ overlay: Overlay) {
        self.overlay = overlay
        super.init(bounds: overlay.rect, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
    }

    required init?(coder: NSCoder) { nil }

    func update(_ overlay: Overlay) {
        self.overlay = overlay
        bounds = overlay.rect
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        overlay.draw(onPageIn: context, hidingText: hidesText)
        context.restoreGState()
    }
}

/// The dashed outline and corner handles around the selected overlay, and the faint outline around a
/// text block under the pointer. Never takes clicks.
final class SelectionChrome: NSView {
    enum Style { case selection, hover, editing }

    var style: Style = .selection { didSet { needsDisplay = true } }
    static let handle: CGFloat = 8

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: Self.handle / 2, dy: Self.handle / 2)
        switch style {
        case .hover:
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2)
            path.lineWidth = 1
            path.stroke()
        case .editing:
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: inner)
            path.lineWidth = 1.5
            path.stroke()
        case .selection:
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: inner)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
            for corner in Self.corners(of: inner) {
                let r = NSRect(x: corner.x - Self.handle / 2, y: corner.y - Self.handle / 2, width: Self.handle, height: Self.handle)
                let dot = NSBezierPath(ovalIn: r)
                NSColor.white.setFill()
                dot.fill()
                NSColor.controlAccentColor.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            }
        }
    }

    static func corners(of r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }
}
