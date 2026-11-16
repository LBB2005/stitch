import Foundation

/// Finds and replaces words inside a text block's text. Matches on the text itself, not on character
/// offsets from PDFKit, since PDFKit's and MuPDF's text differ slightly: ligatures ("ﬁ" reads as "fi")
/// and line breaks (a newline reads as a space).
enum FindReplace {
    static let ligatures: [Character: String] = [
        "ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st",
    ]

    /// Ranges (in `text`'s characters) of every match, in order.
    static func matches(of query: String, in text: String, caseSensitive: Bool) -> [Range<Int>] {
        let original = Array(text)
        // Normalized characters, each pointing back at the original character it came from.
        var norm: [Character] = []
        var back: [Int] = []
        for (i, c) in original.enumerated() {
            let expanded: String = ligatures[c] ?? (c.isNewline ? " " : String(c))
            for e in expanded {
                norm.append(caseSensitive ? e : Character(e.lowercased()))
                back.append(i)
            }
        }
        let q = Array(caseSensitive ? query : query.lowercased()).map { $0.isNewline ? " " : $0 }
        guard !q.isEmpty, q.count <= norm.count else { return [] }
        var found: [Range<Int>] = []
        var i = 0
        while i + q.count <= norm.count {
            if Array(norm[i..<(i + q.count)]) == q {
                let lo = back[i], hi = back[i + q.count - 1] + 1
                if found.last.map({ $0.upperBound <= lo }) ?? true { found.append(lo..<hi) }
                i += q.count
            } else {
                i += 1
            }
        }
        return found
    }

    /// `text` with its `occurrence`-th match (0-based) replaced, or nil when there's no such match.
    static func replace(_ query: String, with replacement: String, in text: String, occurrence: Int,
                        caseSensitive: Bool) -> String? {
        let found = matches(of: query, in: text, caseSensitive: caseSensitive)
        guard found.indices.contains(occurrence) else { return nil }
        var chars = Array(text)
        chars.replaceSubrange(found[occurrence], with: Array(replacement))
        return String(chars)
    }

    /// `text` with every match replaced, and how many there were.
    static func replaceAll(_ query: String, with replacement: String, in text: String,
                           caseSensitive: Bool) -> (text: String, count: Int) {
        let found = matches(of: query, in: text, caseSensitive: caseSensitive)
        var chars = Array(text)
        for r in found.reversed() { chars.replaceSubrange(r, with: Array(replacement)) }
        return (String(chars), found.count)
    }
}
