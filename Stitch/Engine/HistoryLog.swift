import CoreGraphics
import Foundation

/// One change in a document's History, matching one step of its `UndoManager`.
struct HistoryEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case signature, initials, text, textEdit, delete, move, format, fill, other }

    var id: Int
    var action: String
    var summary: String
    var page: Int?
    var kind: Kind
    var time: Date
    /// The overlay it changed, to outline it on the page.
    var overlayID: UUID?
    /// The edited text's block, display space, to outline it on the page.
    var textRect: CGRect?
    /// The `UndoManager` group it belongs to: changes made in one event undo together.
    var group: Int = 0
}

/// The list `UndoManager` can't give: every change, a cursor (entries before it are applied), and the
/// copies saved along the way. A new change after undos drops the undone entries, as `UndoManager` does.
/// Entries in the same undo group (changes made in one event) undo and redo together, as they do in
/// `UndoManager`.
struct HistoryLog: Equatable, Sendable {
    struct Save: Equatable, Sendable, Identifiable {
        /// The cursor when it was saved.
        var position: Int
        var name: String
        var time: Date
        var id: String { "save-\(position)-\(name)-\(time.timeIntervalSince1970)" }
    }

    /// A row of the History panel.
    enum Row: Equatable, Sendable, Identifiable {
        case step(Int)
        /// Consecutive Edit Text changes on one page (still several undo steps).
        case group(Range<Int>)
        case save(Save)

        var id: String {
            switch self {
            case .step(let i): "step-\(i)"
            case .group(let r): "group-\(r.lowerBound)-\(r.upperBound)"
            case .save(let s): s.id
            }
        }
    }

    private(set) var entries: [HistoryEntry] = []
    private(set) var cursor = 0
    private(set) var saves: [Save] = []
    private var nextID = 0

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < entries.count }
    var applied: ArraySlice<HistoryEntry> { entries[..<cursor] }

    /// `group` is the undo group; without one, each entry is its own.
    mutating func record(_ action: String, summary: String, kind: HistoryEntry.Kind, page: Int? = nil,
                         overlayID: UUID? = nil, textRect: CGRect? = nil, group: Int? = nil, time: Date = Date()) {
        entries.removeSubrange(cursor...)
        saves.removeAll { $0.position > cursor }
        entries.append(HistoryEntry(id: nextID, action: action, summary: summary, page: page, kind: kind, time: time,
                                    overlayID: overlayID, textRect: textRect, group: group ?? -(nextID + 1)))
        nextID += 1
        cursor = entries.count
    }

    mutating func undo() {
        guard cursor > 0 else { return }
        let group = entries[cursor - 1].group
        while cursor > 0, entries[cursor - 1].group == group { cursor -= 1 }
    }

    mutating func redo() {
        guard cursor < entries.count else { return }
        let group = entries[cursor].group
        while cursor < entries.count, entries[cursor].group == group { cursor += 1 }
    }

    mutating func saved(_ name: String, time: Date = Date()) {
        saves.append(Save(position: cursor, name: name, time: time))
    }

    /// Oldest first: steps, same-page Edit Text runs grouped, and saves where they happened.
    func rows() -> [Row] {
        var rows: [Row] = []
        var i = 0
        func savesAt(_ position: Int) { for s in saves where s.position == position { rows.append(.save(s)) } }
        savesAt(0)
        while i < entries.count {
            var j = i + 1
            if entries[i].kind == .textEdit {
                while j < entries.count, entries[j].kind == .textEdit, entries[j].page == entries[i].page,
                      !saves.contains(where: { $0.position == j }) { j += 1 }
            }
            rows.append(j - i > 1 ? .group(i..<j) : .step(i))
            savesAt(j)
            i = j
        }
        return rows
    }

    /// Short, readable quote of some text for a summary.
    static func quote(_ text: String, max: Int = 28) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let cut = one.count > max ? String(one.prefix(max - 1)) + "…" : one
        return "“\(cut)”"
    }

    /// "Changed “24 hours’” to “48 hours’”": the words that differ, with a little context.
    static func changeSummary(from old: String, to new: String) -> String {
        let a = Array(old.replacingOccurrences(of: "\n", with: " ")), b = Array(new.replacingOccurrences(of: "\n", with: " "))
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        // Widen to whole words.
        func widen(_ s: [Character], _ lo: Int, _ hi: Int) -> (Int, Int) {
            guard hi > lo else { return (lo, hi) }   // nothing here changed: don't pull in a neighbour
            var l = lo, h = hi
            // Only when the change starts or ends inside a word.
            while l > 0, l < s.count, !s[l].isWhitespace, !s[l - 1].isWhitespace { l -= 1 }
            while h < s.count, h > 0, !s[h].isWhitespace, !s[h - 1].isWhitespace { h += 1 }
            return (l, h)
        }
        let (la, ha) = widen(a, start, endA)
        let (lb, hb) = widen(b, start, max(endB, start))
        let oldPart = String(a[la..<max(ha, la)]).trimmingCharacters(in: .whitespaces)
        let newPart = String(b[lb..<max(hb, lb)]).trimmingCharacters(in: .whitespaces)
        if oldPart.isEmpty { return "Added \(quote(newPart))" }
        if newPart.isEmpty { return "Removed \(quote(oldPart))" }
        return "Changed \(quote(oldPart, max: 20)) to \(quote(newPart, max: 20))"
    }
}
