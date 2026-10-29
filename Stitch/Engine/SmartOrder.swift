import Foundation

/// A run of files that share a name and differ by a number: `Lecture 1`, `Lecture 2`, `Lecture 10`.
struct SeriesInfo: Equatable, Sendable {
    /// Indices into the input names, in series order.
    let order: [Int]
    /// "Sorted by lecture number".
    let label: String
    /// "Lecture 1–10", used to pre-fill the output name.
    let suggestedBaseName: String
}

enum SmartOrder {
    /// Finds a numbered series in file base names (no extensions), or nil when there isn't one,
    /// in which case the files keep the order they were added.
    ///
    /// Names are split into text and number chunks. Walking the numbers left to right, every name must
    /// share the text before each number; numbers that are all equal (the 101 in `CS101 Lecture 3`) are
    /// skipped, and the first number that differs is the one the series is sorted by, naturally, so 10
    /// comes after 9.
    static func series(in names: [String]) -> SeriesInfo? {
        guard names.count >= 2 else { return nil }
        let parsed = names.map(chunks)
        var k = 0
        while true {
            var texts = Set<String>()
            var numbers = Set<Int>()
            for p in parsed {
                guard k < p.numbers.count else { return nil }
                texts.insert(normalize(p.texts[k]))
                numbers.insert(p.numbers[k].value)
            }
            guard texts.count == 1 else { return nil }
            if numbers.count > 1 { return makeSeries(names: names, parsed: parsed, key: k) }
            k += 1
        }
    }

    // MARK: building the series

    private static func makeSeries(names: [String], parsed: [Parsed], key k: Int) -> SeriesInfo {
        let order = names.indices.sorted { a, b in
            let na = parsed[a].numbers[k].value, nb = parsed[b].numbers[k].value
            if na != nb { return na < nb }
            let c = names[a].localizedStandardCompare(names[b])
            return c == .orderedSame ? a < b : c == .orderedAscending
        }
        let first = order.first!, last = order.last!
        let low = parsed[first].numbers[k], high = parsed[last].numbers[k]
        var base = names[first]
        if low.value != high.value {
            base.replaceSubrange(low.range, with: "\(low.digits)–\(high.digits)")
        }
        return SeriesInfo(order: order, label: label(forTextBefore: parsed[first].texts[k]), suggestedBaseName: base)
    }

    private static func label(forTextBefore text: String) -> String {
        let word = normalize(text).split(separator: " ").last.map(String.init) ?? ""
        let isWord = !word.isEmpty && word.allSatisfy(\.isLetter)
        return isWord ? "Sorted by \(word) number" : "Sorted by number"
    }

    // MARK: parsing

    private struct Number {
        let value: Int
        let digits: String
        let range: Range<String.Index>
    }

    /// texts[i] is the text before numbers[i]; texts has one extra trailing entry.
    private struct Parsed {
        var texts: [String] = []
        var numbers: [Number] = []
    }

    private static func chunks(_ name: String) -> Parsed {
        var result = Parsed()
        var textStart = name.startIndex
        for match in name.matches(of: /\d+/) {
            result.texts.append(String(name[textStart..<match.range.lowerBound]))
            let digits = String(name[match.range])
            let value = Int(digits.suffix(18)) ?? Int.max
            result.numbers.append(Number(value: value, digits: digits, range: match.range))
            textStart = match.range.upperBound
        }
        result.texts.append(String(name[textStart...]))
        return result
    }

    /// Case-insensitive, and treats `_`, `-` and `.` like spaces, so `Week_3` matches `week 12`.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacing(/[_\-.\s]+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
