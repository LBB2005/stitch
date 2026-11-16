import CoreGraphics
import Foundation

/// Something left to do in a document: a spot to sign, initial or date, or an empty form field.
struct TodoItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case signature, initials, date, field }

    var kind: Kind
    var page: Int
    /// PDF user space of the page.
    var rect: CGRect
    var label: String
    var done: Bool
    /// The form field, for `field` items and signature fields.
    var fieldName: String?

    var id: String {
        "\(kind.rawValue)-\(page)-\(Int(rect.minX.rounded()))-\(Int(rect.minY.rounded()))-\(fieldName ?? "")"
    }

    var isSigning: Bool { kind != .field }
}

/// Finds the to-dos on a document's pages. Conservative on purpose: a spot is a signature, initials or
/// date label next to a run of underscores, or directly under or beside a blank stretch; plus PDF
/// signature fields and empty text fields. A miss only makes the list shorter, never changes the PDF.
enum TodoFinder {
    /// A line of text on the page, in user space.
    struct Line: Sendable, Equatable {
        var text: String
        var rect: CGRect
    }

    struct Widget: Sendable, Equatable {
        enum Kind: Sendable { case text, signature, other }
        var name: String
        var label: String
        var rect: CGRect
        var kind: Kind
        var value: String
    }

    /// Something placed on a page (an overlay), in user space.
    struct Mark: Sendable, Equatable {
        enum Kind: Sendable { case signature, initials, text }
        var kind: Kind
        var page: Int
        var rect: CGRect
    }

    struct Page: Sendable, Equatable {
        var index: Int
        var bounds: CGRect
        var lines: [Line]
        var widgets: [Widget]
    }

    /// How close (pt) a placed item has to be to count as filling a spot.
    static let reach: CGFloat = 12

    static func find(pages: [Page], marks: [Mark]) -> [TodoItem] {
        var items: [TodoItem] = []
        for page in pages {
            var spots: [TodoItem] = []
            for line in page.lines { spots += labelSpots(line, on: page) }
            // Dates only count beside a signature or initials spot, so "Date of birth" isn't one.
            spots = spots.filter { spot in
                spot.kind != .date || spots.contains { $0.kind != .date && abs($0.rect.minY - spot.rect.minY) < 16 }
            }
            // A signature field already covers its label.
            spots.removeAll { spot in page.widgets.contains { $0.kind != .other && $0.rect.intersects(spot.rect) } }
            var unique: [TodoItem] = []
            for spot in spots where !unique.contains(where: { $0.kind == spot.kind && $0.rect.intersects(spot.rect) }) {
                unique.append(spot)
            }
            for w in page.widgets {
                switch w.kind {
                case .signature:
                    unique.append(TodoItem(kind: .signature, page: page.index, rect: w.rect,
                                           label: w.label.isEmpty ? "Signature" : w.label, done: !w.value.isEmpty, fieldName: w.name))
                case .text:
                    unique.append(TodoItem(kind: .field, page: page.index, rect: w.rect, label: w.label.isEmpty ? w.name : w.label,
                                           done: !w.value.trimmingCharacters(in: .whitespaces).isEmpty, fieldName: w.name))
                case .other:
                    break
                }
            }
            items += unique
        }
        for i in items.indices where items[i].kind != .field && !items[i].done {
            let want: Mark.Kind = switch items[i].kind {
            case .signature: .signature
            case .initials: .initials
            default: .text
            }
            let near = items[i].rect.insetBy(dx: -reach, dy: -reach)
            items[i].done = marks.contains { $0.page == items[i].page && $0.kind == want && $0.rect.intersects(near) }
        }
        return items.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            if abs(a.rect.maxY - b.rect.maxY) > 4 { return a.rect.maxY > b.rect.maxY }
            return a.rect.minX < b.rect.minX
        }
    }

    // MARK: labels

    static func kind(ofLabel raw: String) -> TodoItem.Kind? {
        let s = raw.replacingOccurrences(of: "_", with: " ").lowercased()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":.-()[]*")))
        guard !s.isEmpty, s.count <= 40 else { return nil }
        if s.contains("initial") { return .initials }
        if s.contains("signature") || s.contains("sign here") || s == "sign" || s.hasPrefix("signed") { return .signature }
        let words = s.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains("date"), s.count <= 24 { return .date }
        return nil
    }

    private static func cleanLabel(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":.-*")))
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }

    /// Spots from one line: each "label ____" pair, or a lone label with a blank stretch above or beside.
    private static func labelSpots(_ line: Line, on page: Page) -> [TodoItem] {
        let chars = Array(line.text)
        guard !chars.isEmpty, line.rect.width > 0 else { return [] }
        let charWidth = line.rect.width / CGFloat(chars.count)
        // Runs of 3+ underscores.
        var runs: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "_" {
                var j = i
                while j < chars.count, chars[j] == "_" { j += 1 }
                if j - i >= 3 { runs.append(i..<j) }
                i = j
            } else { i += 1 }
        }
        var spots: [TodoItem] = []
        if !runs.isEmpty {
            var labelStart = 0
            for (n, run) in runs.enumerated() {
                let before = String(chars[labelStart..<run.lowerBound])
                // "Signature ______" or "______ (Signature)" with the label after the last run.
                var label = before
                if kind(ofLabel: label) == nil, n == runs.count - 1 {
                    label = String(chars[run.upperBound...])
                }
                labelStart = run.upperBound
                guard let kind = kind(ofLabel: label) else { continue }
                let x0 = line.rect.minX + CGFloat(run.lowerBound) * charWidth
                let x1 = line.rect.minX + CGFloat(run.upperBound) * charWidth
                let height = kind == .initials ? 22.0 : 28.0
                let rect = CGRect(x: x0, y: line.rect.minY, width: x1 - x0, height: max(height, line.rect.height))
                spots.append(TodoItem(kind: kind, page: page.index, rect: rect, label: cleanLabel(label), done: false))
            }
            return spots
        }
        guard let kind = kind(ofLabel: line.text) else { return [] }
        let others = page.lines.filter { $0 != line }
        func blank(_ r: CGRect) -> Bool {
            page.bounds.insetBy(dx: -1, dy: -1).contains(r) && !others.contains { $0.rect.intersects(r) }
        }
        let width = max(line.rect.width, kind == .initials ? 60 : kind == .date ? 110 : 150)
        let height: CGFloat = kind == .initials ? 22 : 28
        let above = CGRect(x: line.rect.minX, y: line.rect.maxY + 1, width: width, height: height)
        let besideWidth = min(kind == .initials ? 70 : kind == .date ? 110 : 170, page.bounds.maxX - 18 - line.rect.maxX)
        let beside = CGRect(x: line.rect.maxX + 4, y: line.rect.minY - 2, width: max(besideWidth, 0), height: height)
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        let order = trimmed.hasSuffix(":") ? [beside, above] : [above, beside]
        guard let rect = order.first(where: { $0.width >= 30 && blank($0) }) else { return [] }
        return [TodoItem(kind: kind, page: page.index, rect: rect, label: cleanLabel(line.text), done: false)]
    }
}
