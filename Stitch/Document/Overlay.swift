import CoreGraphics
import CoreText
import Foundation

/// Something placed on top of a page: a signature, initials or a text box (dates and "my info" items
/// are text boxes). Movable and deletable until the copy is saved, then stamped in as vector content.
struct Overlay: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case signature(Signature)
        case initials(Signature)
        case text(TextBox)
    }

    let id: UUID
    var page: Int
    /// PDF user space of the page (PDFKit's page coordinates).
    var rect: CGRect
    /// The page's /Rotate, so the overlay is drawn upright as the page is shown.
    var rotation: Int
    var kind: Kind

    init(id: UUID = UUID(), page: Int, rect: CGRect, rotation: Int, kind: Kind) {
        self.id = id
        self.page = page
        self.rect = rect
        self.rotation = rotation
        self.kind = kind
    }

    var isSigning: Bool {
        switch kind {
        case .signature, .initials: true
        case .text: false
        }
    }

    var textBox: TextBox? {
        if case .text(let box) = kind { return box }
        return nil
    }

    var uprightSize: CGSize { PageGeometry.uprightSize(of: rect, rotation: rotation) }

    /// Draws the overlay into its own upright box `(0, 0, uprightSize)`.
    func drawContent(in ctx: CGContext, hidingText: Bool = false) {
        let size = uprightSize
        switch kind {
        case .signature(let sig), .initials(let sig):
            sig.draw(in: ctx, size: size)
        case .text(let box):
            box.draw(in: ctx, size: size, hidingText: hidingText)
        }
    }

    /// Draws the overlay onto its page, in page user space.
    func draw(onPageIn ctx: CGContext, hidingText: Bool = false) {
        ctx.saveGState()
        ctx.concatenate(PageGeometry.uprightTransform(for: rect, rotation: rotation))
        drawContent(in: ctx, hidingText: hidingText)
        ctx.restoreGState()
    }

    /// Text boxes resize by scaling their font; everything keeps its shape.
    func resized(to newRect: CGRect) -> Overlay {
        var copy = self
        if case .text(var box) = kind {
            let oldHeight = max(uprightSize.height, 1)
            let newHeight = PageGeometry.uprightSize(of: newRect, rotation: rotation).height
            box.fontSize = min(max(box.fontSize * newHeight / oldHeight, 4), 144)
            copy.kind = .text(box)
            let size = PageGeometry.userSize(ofUpright: box.naturalSize, rotation: rotation)
            copy.rect = CGRect(origin: newRect.origin, size: size)
        } else {
            copy.rect = newRect
        }
        return copy
    }
}

/// A box of typed text. It sizes itself to its text; Shift-Return adds lines.
struct TextBox: Equatable, Sendable {
    enum Ink: String, CaseIterable, Sendable {
        case black, blue, red

        var cgColor: CGColor {
            switch self {
            case .black: CGColor(gray: 0.05, alpha: 1)
            case .blue: CGColor(red: 0.05, green: 0.22, blue: 0.7, alpha: 1)
            case .red: CGColor(red: 0.78, green: 0.1, blue: 0.1, alpha: 1)
            }
        }

        var label: String { rawValue.capitalized }
    }

    var text: String
    var fontSize: CGFloat = 12
    var bold = false
    var ink: Ink = .black
    /// Paints the box white first: how you cover and retype on a scan.
    var whiteBackground = false

    static let padding: CGFloat = 2

    var fontName: String { bold ? "Helvetica-Bold" : "Helvetica" }

    var font: CTFont { CTFontCreateWithName(fontName as CFString, fontSize, nil) }

    var lines: [String] {
        let parts = text.components(separatedBy: "\n")
        return parts.isEmpty ? [""] : parts
    }

    var lineHeight: CGFloat {
        let f = font
        return ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
    }

    /// Upright size that fits the text (at least a few characters wide so an empty box can be clicked).
    var naturalSize: CGSize {
        let f = font
        let widest = lines.map { line -> CGFloat in
            let ct = CTLineCreateWithAttributedString(attributed(line, font: f, color: ink.cgColor))
            return CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
        }.max() ?? 0
        let width = max(widest, fontSize * 2) + Self.padding * 2
        return CGSize(width: ceil(width), height: CGFloat(lines.count) * lineHeight + Self.padding * 2)
    }

    func draw(in ctx: CGContext, size: CGSize, hidingText: Bool = false) {
        ctx.saveGState()
        if whiteBackground {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        if !hidingText {
            let f = font
            let ascent = CTFontGetAscent(f)
            ctx.textMatrix = .identity
            for (i, line) in lines.enumerated() {
                let ct = CTLineCreateWithAttributedString(attributed(line, font: f, color: ink.cgColor))
                ctx.textPosition = CGPoint(x: Self.padding, y: size.height - Self.padding - ascent - CGFloat(i) * lineHeight)
                CTLineDraw(ct, ctx)
            }
        }
        ctx.restoreGState()
    }

    private func attributed(_ s: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }
}
