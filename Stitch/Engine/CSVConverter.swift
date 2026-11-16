import CoreGraphics
import CoreText
import Foundation

/// CSV/TSV → PDF table pages, drawn by Stitch itself so it works without LibreOffice. Columns always fit
/// the page width: a table too wide for a portrait page turns landscape, then its text shrinks (never below
/// `minFontSize`), then its widest columns wrap. Long tables run onto more pages with the header row
/// repeated. The text stays real text, so it can be selected and read by AI chats.
enum CSVConverter {
    enum Failure: LocalizedError {
        case unreadable(String)
        case empty(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)."
            case .empty(let name): "\(name) has no rows."
            case .tooLarge(let name): "\(name) is too big a table to turn into pages."
            }
        }
    }

    static let fontSize: CGFloat = 9
    static let minFontSize: CGFloat = 6
    static let margin: CGFloat = 28
    /// A column's natural width is capped at this (at `fontSize`); longer text wraps inside it.
    static let maxColumnWidth: CGFloat = 220
    /// Rows measured to find each column's natural width; enough to be representative, quick on big files.
    static let sampleRows = 1000
    /// Rows × columns above this are refused: a file made of one very wide row and many short ones would
    /// otherwise be padded out to billions of cells.
    static let maxCells = 2_000_000

    static func writePDF(from src: URL, to dst: URL) throws {
        guard let data = try? Data(contentsOf: src), let text = decode(data) else {
            throw Failure.unreadable(src.lastPathComponent)
        }
        let parsed = parse(text, delimiter: delimiter(for: src, text: text))
        guard parsed.count * (parsed.map(\.count).max() ?? 0) <= maxCells else { throw Failure.tooLarge(src.lastPathComponent) }
        let rows = clean(parsed)
        guard !rows.isEmpty else { throw Failure.empty(src.lastPathComponent) }
        try draw(Table(rows: rows), title: src.lastPathComponent, to: dst)
    }

    // MARK: reading

    /// UTF-8 (with or without a BOM) or UTF-16 with a BOM; anything else is read as Windows Latin 1, which is
    /// what Excel writes for "CSV" on many machines. Binary files are refused.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.prefix(4096).contains(0) { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
        return text.map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
    }

    /// Tab for .tsv/.tab; otherwise Excel's `sep=;` line if there is one, else whichever of comma,
    /// semicolon and tab appears most in the first line (semicolons are common in European exports).
    static func delimiter(for url: URL, text: String) -> Unicode.Scalar {
        if ["tsv", "tab"].contains(url.pathExtension.lowercased()) { return "\t" }
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" && $0 != "\r\n" }
        if firstLine.lowercased().hasPrefix("sep="), let sep = firstLine.unicodeScalars.dropFirst(4).first {
            return sep
        }
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        for c in firstLine.unicodeScalars {
            if c == "\"" { quoted.toggle() } else if !quoted, counts[c] != nil { counts[c]! += 1 }
        }
        let best = counts.max { $0.value < $1.value || ($0.value == $1.value && $1.key == ",") }!
        return best.value > 0 ? best.key : ","
    }

    /// RFC 4180: quoted fields may hold delimiters, line breaks and doubled quotes; rows end with LF, CRLF or CR.
    static func parse(_ text: String, delimiter: Unicode.Scalar) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var atFieldStart = true
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"", atFieldStart {
                quoted = true
                atFieldStart = false
            } else if c == delimiter {
                row.append(String(field))
                field = String.UnicodeScalarView()
                atFieldStart = true
            } else if c == "\n" || c == "\r" {
                row.append(String(field))
                rows.append(row)
                row = []
                field = String.UnicodeScalarView()
                atFieldStart = true
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
            } else {
                field.append(c)
                atFieldStart = false
            }
            i += 1
        }
        if !row.isEmpty || !field.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }

    /// Drops Excel's `sep=` line, blank rows and columns that are empty all the way down, and pads short rows.
    static func clean(_ parsed: [[String]]) -> [[String]] {
        var rows = parsed
        if let first = rows.first, first.count <= 2, first[0].lowercased().hasPrefix("sep=") { rows.removeFirst() }
        rows.removeAll { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        let used = rows.map { row in row.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0 + 1 } ?? 0 }
        let columns = used.max() ?? 0
        return rows.map { row in
            let row = Array(row.prefix(columns))
            return row + Array(repeating: "", count: columns - row.count)
        }
    }

    // MARK: layout

    struct Table {
        let header: [String]
        let body: [[String]]
        var columnCount: Int { header.count }

        init(rows: [[String]]) {
            header = rows[0]
            body = Array(rows.dropFirst())
        }
    }

    struct Layout: Equatable {
        var pageSize: CGSize
        var fontSize: CGFloat
        var columnWidths: [CGFloat]
        var rightAligned: [Bool]
        var headerHeight: CGFloat
        var rowHeights: [CGFloat]
        /// Body rows on each page.
        var pages: [Range<Int>]

        var landscape: Bool { pageSize.width > pageSize.height }
        var padX: CGFloat { fontSize * 0.45 }
        var padY: CGFloat { fontSize * 0.3 }
        var lineHeight: CGFloat { (fontSize * 1.25).rounded(.up) }
        var footerHeight: CGFloat { 18 }
        var bodyTop: CGFloat { pageSize.height - CSVConverter.margin - headerHeight }
        var bodyBottom: CGFloat { CSVConverter.margin + footerHeight }
    }

    /// A4, or US Letter where that's the local paper size. Portrait unless the table is too wide for it.
    static var portraitPage: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    static func layout(_ table: Table, portrait: CGSize = portraitPage) -> Layout {
        let font = CSVConverter.font(fontSize, bold: false)
        let bold = CSVConverter.font(fontSize, bold: true)
        let sample = table.body.prefix(sampleRows)

        // Natural widths at `fontSize`, padding included.
        let pad = fontSize * 0.45 * 2
        var natural = (0..<table.columnCount).map { c in
            min(maxColumnWidth, max(width(table.header[c], bold), sample.map { width($0[c], font) }.max() ?? 0)) + pad
        }
        natural = natural.map { max($0, fontSize * 2) }
        let total = natural.reduce(0, +)
        // The narrowest each column can be without breaking a word: in the body only, or the header too.
        let bodyWords = (0..<table.columnCount).map { c in
            min(natural[c], (sample.map { longestWord($0[c], font) }.max() ?? 0) + pad)
        }
        let allWords = (0..<table.columnCount).map { c in
            min(natural[c], max(bodyWords[c], longestWord(table.header[c], bold) + pad))
        }

        var page = portrait
        var size = fontSize
        if total > portrait.width - 2 * margin {
            page = CGSize(width: portrait.height, height: portrait.width)
            size = max(minFontSize, min(fontSize, (fontSize * (page.width - 2 * margin) / total * 2).rounded(.down) / 2))
        }
        let scale = size / fontSize
        let available = page.width - 2 * margin
        let floors = [allWords, bodyWords].first { $0.reduce(0, +) * scale <= available } ?? []
        let widths = fit(natural.map { $0 * scale }, floors: floors.map { $0 * scale }, into: available)
        let rightAligned = (0..<table.columnCount).map { c in
            let values = sample.map { $0[c].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return !values.isEmpty && values.filter(isNumeric).count * 5 >= values.count * 4
        }

        var layout = Layout(pageSize: page, fontSize: size, columnWidths: widths, rightAligned: rightAligned,
                            headerHeight: 0, rowHeights: [], pages: [])
        let maxRow = page.height - 2 * margin - layout.footerHeight
        layout.headerHeight = min(maxRow / 3, rowHeight(table.header, layout, bold: true))
        layout.rowHeights = table.body.map { min(maxRow - layout.headerHeight, rowHeight($0, layout, bold: false)) }

        var start = 0
        var y = layout.bodyTop
        for (r, h) in layout.rowHeights.enumerated() {
            if y - h < layout.bodyBottom, r > start {
                layout.pages.append(start..<r)
                start = r
                y = layout.bodyTop
            }
            y -= h
        }
        layout.pages.append(start..<table.body.count)
        return layout
    }

    /// Every column gets its floor (when given), then the room left goes to the columns that want more:
    /// those wanting less than an equal share get all of it, the rest split what's left equally (and wrap).
    static func fit(_ natural: [CGFloat], floors: [CGFloat] = [], into width: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > width else { return natural }
        if !floors.isEmpty {
            let extra = fit(zip(natural, floors).map { $0 - $1 }, into: width - floors.reduce(0, +))
            return zip(floors, extra).map { $0 + $1 }
        }
        var widths = natural
        var remaining = width
        var open = Array(natural.indices)
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let small = open.filter { natural[$0] <= share }
            if small.isEmpty {
                for c in open { widths[c] = share }
                break
            }
            for c in small { remaining -= natural[c] }
            open.removeAll { small.contains($0) }
        }
        return widths
    }

    private static func rowHeight(_ row: [String], _ layout: Layout, bold: Bool) -> CGFloat {
        let font = CSVConverter.font(layout.fontSize, bold: bold)
        var lines = 1
        for (c, text) in row.enumerated() where !text.isEmpty {
            let room = layout.columnWidths[c] - 2 * layout.padX
            // No glyph is wider than 1 em, so short single-line text needs no measuring.
            if !text.contains(where: \.isNewline), CGFloat(text.count) * layout.fontSize <= room { continue }
            let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, font, right: false))
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil, CGSize(width: room, height: .greatestFiniteMagnitude), nil)
            lines = max(lines, Int((fitted.height / layout.lineHeight).rounded(.up)))
        }
        return CGFloat(lines) * layout.lineHeight + 2 * layout.padY
    }

    /// Amounts like 12, -4.50, 1,200.00, $5, (3.1) and 12% — not dates, codes or phone numbers.
    static func isNumeric(_ text: String) -> Bool {
        text.wholeMatch(of: /[-+(]?[$€£¥]?\d[\d,. ]*%?\)?/) != nil
    }

    // MARK: drawing

    private static func draw(_ table: Table, title: String, to dst: URL) throws {
        let layout = layout(table)
        var box = CGRect(origin: .zero, size: layout.pageSize)
        let info = [kCGPDFContextTitle: title] as CFDictionary
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, info) else {
            throw Failure.unreadable(title)
        }
        let font = CSVConverter.font(layout.fontSize, bold: false)
        let bold = CSVConverter.font(layout.fontSize, bold: true)
        let tableWidth = layout.columnWidths.reduce(0, +)
        let grid = CGColor(gray: 0.78, alpha: 1)

        for (n, rows) in layout.pages.enumerated() {
            try Task.checkCancellation()
            ctx.beginPDFPage(nil)
            var y = layout.pageSize.height - margin
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
            ctx.fill(CGRect(x: margin, y: y - layout.headerHeight, width: tableWidth, height: layout.headerHeight))
            drawRow(table.header, top: y, height: layout.headerHeight, font: bold, layout: layout, in: ctx)
            y -= layout.headerHeight
            var lines = [y]
            for r in rows {
                drawRow(table.body[r], top: y, height: layout.rowHeights[r], font: font, layout: layout, in: ctx)
                y -= layout.rowHeights[r]
                lines.append(y)
            }

            ctx.setStrokeColor(grid)
            ctx.setLineWidth(0.5)
            let top = layout.pageSize.height - margin
            ctx.stroke(CGRect(x: margin, y: y, width: tableWidth, height: top - y))
            for line in lines { ctx.strokeLineSegments(between: [CGPoint(x: margin, y: line), CGPoint(x: margin + tableWidth, y: line)]) }
            var x = margin
            for w in layout.columnWidths.dropLast() {
                x += w
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: top), CGPoint(x: x, y: y)])
            }

            if layout.pages.count > 1 {
                let footer = attributed("\(title) · page \(n + 1) of \(layout.pages.count)", CSVConverter.font(7, bold: false),
                                        right: false, gray: 0.45)
                let line = CTLineCreateWithAttributedString(footer)
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: (layout.pageSize.width - w) / 2, y: margin)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func drawRow(_ row: [String], top: CGFloat, height: CGFloat, font: CTFont, layout: Layout,
                                in ctx: CGContext) {
        var x = margin
        for (c, text) in row.enumerated() {
            let w = layout.columnWidths[c]
            defer { x += w }
            guard !text.isEmpty else { continue }
            let cell = CGRect(x: x + layout.padX, y: top - height + layout.padY,
                              width: w - 2 * layout.padX, height: height - 2 * layout.padY)
            let string = attributed(text, font, right: layout.rightAligned[c])
            let path = CGPath(rect: cell.insetBy(dx: 0, dy: -1), transform: nil)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(), path, nil)
            ctx.saveGState()
            ctx.clip(to: cell.insetBy(dx: -layout.padX / 2, dy: -layout.padY))
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: text

    private static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func width(_ text: String, _ font: CTFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return text.split(whereSeparator: \.isNewline).map { line in
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(String(line), font, right: false)),
                                               nil, nil, nil))
        }.max() ?? 0
    }

    private static func longestWord(_ text: String, _ font: CTFont) -> CGFloat {
        // A point to spare: a word exactly as wide as its column still gets broken.
        (text.split(whereSeparator: { $0.isWhitespace }).map { width(String($0), font) }.max() ?? 0).rounded(.up) + 1
    }

    private static func attributed(_ text: String, _ font: CTFont, right: Bool, gray: CGFloat = 0) -> CFAttributedString {
        var alignment: CTTextAlignment = right ? .right : .left
        var breakMode: CTLineBreakMode = .byWordWrapping
        let style = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &breakMode) { b in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: a.count, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: b.count, value: b.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
            kCTParagraphStyleAttributeName: style,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }
}
