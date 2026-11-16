import Foundation

/// How well a search typed into the command bar (⌘K) matches a title. Pure, so it's unit-tested.
enum CommandMatch {
    /// nil when it doesn't match; higher is better. Every word typed has to appear in the title, as the
    /// start of the title (best), the start of a word in it, or anywhere in it.
    static func score(_ query: String, _ title: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        let text = title.lowercased()
        var total = 0
        for word in words {
            guard let range = text.range(of: word) else { return nil }
            if range.lowerBound == text.startIndex {
                total += 100
            } else if let before = text[..<range.lowerBound].last, !before.isLetter, !before.isNumber {
                total += 60
            } else {
                total += 20
            }
        }
        // Shorter titles win among equals: "Lease.pdf" before "Lease renewal 2025.pdf".
        return total * 10 - min(text.count, 99) / 10
    }
}

/// A new name typed over a document's title, made safe for a file name.
enum FileRename {
    /// The base name to use (no extension), or nil when there's nothing usable. A typed ".pdf" is
    /// dropped, slashes and colons become dashes, and leading dots go (they'd hide the file).
    static func baseName(_ typed: String, extension ext: String) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, name.lowercased().hasSuffix("." + ext.lowercased()) {
            name = String(name.dropLast(ext.count + 1))
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // APFS allows 255 UTF-8 bytes per name, extension included.
        while name.utf8.count + ext.utf8.count + 1 > 255 { name.removeLast() }
        return name
    }
}
