import CoreGraphics
import CoreText
import Foundation

/// A line of text already in the PDF, in display space (top-left origin, y down).
struct TextLine: Equatable, Sendable {
    var text: String
    var rect: CGRect
    /// Display-space y of the baseline.
    var baseline: CGFloat
    var size: CGFloat
}

/// A paragraph of text already in the PDF, as MuPDF groups it, with the style of its first letters.
struct TextBlock: Equatable, Sendable {
    var page: Int
    /// Display space.
    var rect: CGRect
    var lines: [TextLine]
    /// The installed font new text is drawn in, and whether it is the PDF's own font.
    var fontName: String
    var exactFont: Bool
    var fontSize: CGFloat
    var argb: UInt32

    var text: String { lines.map(\.text).joined(separator: "\n") }

    /// Distance between baselines (one line: 1.2 × the font size).
    var lineHeight: CGFloat {
        guard lines.count >= 2 else { return fontSize * 1.2 }
        return (lines[lines.count - 1].baseline - lines[0].baseline) / CGFloat(lines.count - 1)
    }

    var firstBaselineOffset: CGFloat { (lines.first?.baseline ?? rect.maxY) - rect.minY }

    var color: CGColor {
        CGColor(red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
    }

    /// Thin bands through the middle of each line, just above the baseline. Text removal takes any glyph
    /// these touch, so each line's own glyphs go and the lines above and below are left alone.
    var removalRects: [CGRect] {
        lines.compactMap { line in
            guard line.rect.width > 0.6 else { return nil }
            return CGRect(x: line.rect.minX + 0.3, y: line.baseline - line.size * 0.45,
                          width: line.rect.width - 0.6, height: line.size * 0.25)
        }
    }
}

/// A change to text already in the PDF: the block it replaces and the new text (lines split by "\n").
struct TextEdit: Identifiable, Equatable, Sendable {
    let id: UUID
    var block: TextBlock
    var text: String

    init(id: UUID = UUID(), block: TextBlock, text: String) {
        self.id = id
        self.block = block
        self.text = text
    }

    var page: Int { block.page }
}

enum TextLayout {
    /// Groups MuPDF's characters into blocks and lines. Blocks with no visible characters are dropped.
    static func blocks(from chars: [MuPDFDocument.Char], page: Int) -> [TextBlock] {
        var order: [Int] = []
        var byBlock: [Int: [MuPDFDocument.Char]] = [:]
        for c in chars {
            if byBlock[c.block] == nil { order.append(c.block) }
            byBlock[c.block, default: []].append(c)
        }
        return order.compactMap { id -> TextBlock? in
            let chars = byBlock[id] ?? []
            var lineOrder: [Int] = []
            var byLine: [Int: [MuPDFDocument.Char]] = [:]
            for c in chars {
                if byLine[c.line] == nil { lineOrder.append(c.line) }
                byLine[c.line, default: []].append(c)
            }
            let lines = lineOrder.compactMap { lineID -> TextLine? in
                let cs = byLine[lineID] ?? []
                let visible = cs.filter { !$0.scalar.properties.isWhitespace }
                guard let first = visible.first else { return nil }
                var text = String(String.UnicodeScalarView(cs.map(\.scalar)))
                text = text.trimmingCharacters(in: .whitespaces)
                let rect = visible.dropFirst().reduce(first.box) { $0.union($1.box) }
                return TextLine(text: text, rect: rect, baseline: first.origin.y, size: mostCommon(visible.map(\.size)))
            }
            guard let firstLine = lines.first,
                  let styleChar = chars.first(where: { !$0.scalar.properties.isWhitespace }) else { return nil }
            let rect = lines.dropFirst().reduce(firstLine.rect) { $0.union($1.rect) }
            let match = FontMatcher.match(pdfFontName: styleChar.fontName, bold: styleChar.bold, italic: styleChar.italic,
                                          serif: styleChar.serif, mono: styleChar.mono)
            return TextBlock(page: page, rect: rect, lines: lines, fontName: match.postScriptName, exactFont: match.exact,
                             fontSize: mostCommon(lines.map(\.size)), argb: styleChar.argb)
        }
    }

    private static func mostCommon(_ sizes: [CGFloat]) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for s in sizes { counts[(s * 10).rounded() / 10, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? 12
    }

    // MARK: laying out new text

    struct Laid: Equatable, Sendable {
        /// Display space: where the new text goes (the block's box, grown downward if needed).
        var rect: CGRect
        var fontSize: CGFloat
        var lineHeight: CGFloat
        var firstBaselineOffset: CGFloat
        /// Each drawn line and its x offset from `rect.minX`.
        var lines: [(text: String, x: CGFloat)]
        var shrunk: Bool
        var grew: Bool

        static func == (a: Laid, b: Laid) -> Bool {
            a.rect == b.rect && a.fontSize == b.fontSize && a.lines.map(\.text) == b.lines.map(\.text)
                && a.lines.map(\.x) == b.lines.map(\.x) && a.shrunk == b.shrunk && a.grew == b.grew
        }
    }

    /// Lays the edited text out in the block's place: the original line breaks are kept, a line that no
    /// longer fits wraps at the block's width, and if the text is now taller it shrinks to at most 80%
    /// of the original size, then the box grows downward.
    static func layout(_ edit: TextEdit) -> Laid {
        let block = edit.block
        let width = max(block.rect.width * 1.02, block.fontSize * 3)
        var scale: CGFloat = 1
        var attempt = lay(edit.text, block: block, scale: scale, width: width)
        let fits = { (l: Laid) in l.rect.height <= block.rect.height + block.fontSize * 0.35 }
        while !fits(attempt), scale > 0.8 + 0.001 {
            scale = max(scale - 0.02, 0.8)
            attempt = lay(edit.text, block: block, scale: scale, width: width)
        }
        attempt.shrunk = scale < 1
        attempt.grew = !fits(attempt)
        if !attempt.grew { attempt.rect.size.height = max(attempt.rect.height, block.rect.height) }
        return attempt
    }

    private static func lay(_ text: String, block: TextBlock, scale: CGFloat, width: CGFloat) -> Laid {
        let size = block.fontSize * scale
        let font = CTFontCreateWithName(block.fontName as CFString, size, nil)
        let pitch = block.lineHeight * scale
        let firstOffset = block.firstBaselineOffset * scale   // keeps the top of the text where it was
        var out: [(String, CGFloat)] = []
        for (i, para) in text.components(separatedBy: "\n").enumerated() {
            let indent = i < block.lines.count ? max(block.lines[i].rect.minX - block.rect.minX, 0) : 0
            let parts = wrap(para, font: font, width: width - indent)
            for (j, part) in parts.enumerated() { out.append((part, j == 0 ? indent : 0)) }
        }
        if out.isEmpty { out = [("", 0)] }
        let descent = CTFontGetDescent(font)
        let height = firstOffset + CGFloat(out.count - 1) * pitch + descent
        let rect = CGRect(x: block.rect.minX, y: block.rect.minY, width: width, height: max(height, size))
        return Laid(rect: rect, fontSize: size, lineHeight: pitch, firstBaselineOffset: firstOffset,
                    lines: out, shrunk: false, grew: false)
    }

    private static func wrap(_ text: String, font: CTFont, width: CGFloat) -> [String] {
        guard !text.isEmpty else { return [""] }
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = text as NSString
        var lines: [String] = []
        var start = 0
        while start < ns.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            lines.append(ns.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespaces))
            start += count
        }
        return lines.isEmpty ? [text] : lines
    }

    /// Draws laid-out text into a stamp `(0, 0, laid.rect.size)`, y up.
    static func draw(_ laid: Laid, fontName: String, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName(fontName as CFString, laid.fontSize, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        for (i, line) in laid.lines.enumerated() where !line.text.isEmpty {
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
            let baseline = laid.firstBaselineOffset + CGFloat(i) * laid.lineHeight
            ctx.textPosition = CGPoint(x: line.x, y: laid.rect.height - baseline)
            CTLineDraw(ct, ctx)
        }
        ctx.restoreGState()
    }
}
