import CoreText
import Foundation

/// Picks an installed font for rewriting text that used a PDF font. PDFs usually embed partial copies
/// of their fonts (only the letters the document used), so new text always uses an installed font:
/// the exact PostScript name if it's installed, else the same family and weight, else Times or Helvetica.
enum FontMatcher {
    struct Match: Equatable, Sendable {
        let postScriptName: String
        let exact: Bool
    }

    /// "ABCDEF+Helvetica-Bold" → "Helvetica-Bold".
    static func stripSubset(_ name: String) -> String {
        guard let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6,
              name[..<plus].allSatisfy({ $0.isUppercase && $0.isASCII }) else { return name }
        return String(name[name.index(after: plus)...])
    }

    static func match(pdfFontName raw: String, bold: Bool, italic: Bool, serif: Bool, mono: Bool) -> Match {
        let name = stripSubset(raw).replacingOccurrences(of: ",", with: "-")
        if isInstalled(name) { return Match(postScriptName: name, exact: true) }
        let lower = name.lowercased()
        let isBold = bold || ["bold", "black", "heavy", "semibold", "demi"].contains { lower.contains($0) }
        let isItalic = italic || lower.contains("italic") || lower.contains("oblique")

        // Same family under the installed naming ("Arial,Bold" → Arial-BoldMT, "TimesNewRoman" → Times New Roman).
        let family = String(name.split(separator: "-").first ?? Substring(name))
        for candidate in familyCandidates(family) {
            if let ps = installed(family: candidate, bold: isBold, italic: isItalic) {
                return Match(postScriptName: ps, exact: false)
            }
        }

        let fallbackFamily: String
        if mono || ["courier", "mono", "consol", "menlo"].contains(where: lower.contains) {
            fallbackFamily = "Courier"
        } else if serif || ["times", "serif", "roman", "georgia", "garamond", "cambria", "minion", "palatino", "book"]
            .contains(where: lower.contains), !lower.contains("sans") {
            fallbackFamily = "Times New Roman"
        } else {
            fallbackFamily = "Helvetica"
        }
        let ps = installed(family: fallbackFamily, bold: isBold, italic: isItalic) ?? "Helvetica"
        return Match(postScriptName: ps, exact: false)
    }

    private static func familyCandidates(_ family: String) -> [String] {
        var spaced = ""
        for (i, ch) in family.enumerated() {
            if i > 0, ch.isUppercase, let prev = spaced.last, prev.isLowercase { spaced.append(" ") }
            spaced.append(ch)
        }
        let trimmed = spaced.replacingOccurrences(of: " PSMT", with: "").replacingOccurrences(of: "MT", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Array(NSOrderedSet(array: [family, spaced, trimmed])) as? [String] ?? [family]
    }

    static func isInstalled(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName
    }

    private static func installed(family: String, bold: Bool, italic: Bool) -> String? {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let attrs: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: traits.rawValue],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        guard let found = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet)
        else { return nil }
        let font = CTFontCreateWithFontDescriptor(found, 12, nil)
        guard (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame else { return nil }
        return CTFontCopyPostScriptName(font) as String
    }
}
