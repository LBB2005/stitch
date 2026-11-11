import CoreGraphics
import CoreText
import Foundation

/// A saved signature or set of initials: vector strokes (drawn) or text in a script font (typed).
struct Signature: Codable, Equatable, Sendable {
    enum Style: String, Codable, Sendable { case drawn, typed }

    var style: Style
    /// Drawn: strokes in a box one unit high and `aspect` wide, y up.
    var strokes: [[CGPoint]]
    /// Width ÷ height of the signature's natural box.
    var aspect: CGFloat
    /// Typed: the text and the script font's PostScript name.
    var text: String
    var fontName: String
    /// Stroke width as a fraction of the height.
    var inkWidth: CGFloat

    /// Script fonts that ship with macOS, in the order the Type tab offers them.
    static let scriptFonts: [(name: String, label: String)] = [
        ("SignPainter-HouseScript", "SignPainter"),
        ("SnellRoundhand", "Snell Roundhand"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Apple-Chancery", "Apple Chancery"),
        ("SavoyeLetPlain", "Savoye"),
    ]

    static func drawn(strokes raw: [[CGPoint]], inkWidth: CGFloat = 0.03) -> Signature? {
        let points = raw.flatMap { $0 }
        guard let first = points.first, points.count >= 2 else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let height = max(maxY - minY, 1), width = max(maxX - minX, 1)
        // A little room around the ink so thick strokes aren't clipped.
        let pad = max(width, height) * 0.04
        let box = CGRect(x: minX - pad, y: minY - pad, width: width + pad * 2, height: height + pad * 2)
        let strokes = raw.filter { !$0.isEmpty }.map { stroke in
            stroke.map { CGPoint(x: ($0.x - box.minX) / box.height, y: ($0.y - box.minY) / box.height) }
        }
        return Signature(style: .drawn, strokes: strokes, aspect: box.width / box.height, text: "", fontName: "",
                         inkWidth: inkWidth)
    }

    static func typed(_ text: String, fontName: String) -> Signature? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let bounds = typedBounds(text, fontName: fontName, size: 100)
        return Signature(style: .typed, strokes: [], aspect: max(bounds.width, 1) / max(bounds.height, 1), text: text,
                         fontName: fontName, inkWidth: 0)
    }

    /// The natural size for a signature this tall.
    func size(height: CGFloat) -> CGSize { CGSize(width: height * aspect, height: height) }

    // MARK: drawing

    static let ink = CGColor(red: 0.07, green: 0.1, blue: 0.24, alpha: 1)

    /// Draws into `(0, 0, size)` (y up), keeping the shape and centring it.
    func draw(in ctx: CGContext, size: CGSize, color: CGColor = Signature.ink) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(size.width / aspect, size.height)
        let origin = CGPoint(x: (size.width - aspect * scale) / 2, y: (size.height - scale) / 2)
        ctx.saveGState()
        switch style {
        case .drawn:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(inkWidth * scale, 0.4))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes {
                let pts = stroke.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
                ctx.addPath(Self.smoothPath(pts))
                ctx.strokePath()
            }
        case .typed:
            let bounds = Self.typedBounds(text, fontName: fontName, size: 100)
            let fontSize = 100 * scale / max(bounds.height, 1)
            let line = Self.line(text, fontName: fontName, size: fontSize, color: color)
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: origin.x - b.minX, y: origin.y - b.minY)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    /// Smooth curves through the sampled points (midpoint quadratic curves).
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func line(_ text: String, fontName: String, size: CGFloat, color: CGColor) -> CTLine {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }

    static func typedBounds(_ text: String, fontName: String, size: CGFloat) -> CGRect {
        CTLineGetBoundsWithOptions(line(text, fontName: fontName, size: size, color: ink), .useGlyphPathBounds)
    }
}
