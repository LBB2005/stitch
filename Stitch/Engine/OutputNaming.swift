import Foundation

enum OutputNaming {
    /// "2026-10-21 1352"
    static func timestamp(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.string(from: date)
    }

    /// The pre-filled name: the series range if there is one (`Lecture 1–3.pdf`), the file's own name
    /// when there is just one, otherwise `Merged – 2026-10-21 1352.pdf`.
    static func suggestion(baseNames: [String], series: SeriesInfo?, date: Date = .now) -> String {
        if let series { return series.suggestedBaseName + ".pdf" }
        if baseNames.count == 1 { return baseNames[0] + ".pdf" }
        return "Merged – \(timestamp(date)).pdf"
    }

    /// The name the person typed without any extension Stitch would add itself, made safe for a filename.
    static func baseName(of fieldValue: String) -> String {
        var name = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in ["pdf", "jpg", "jpeg"] where name.lowercased().hasSuffix("." + ext) {
            name = String(name.dropLast(ext.count + 1))
            break
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    /// `folder/base.ext`, or `folder/base (2).ext` and so on if that already exists. Never overwrites.
    /// Pass a nil extension for a folder.
    static func uniqueURL(in folder: URL, base: String, ext: String?,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) (\(n))"
            let file = ext.map { "\(name).\($0)" } ?? name
            return folder.appendingPathComponent(file, isDirectory: ext == nil)
        }
        var n = 1
        while exists(candidate(n)) { n += 1 }
        return candidate(n)
    }
}
