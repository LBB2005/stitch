import Foundation

/// Save Copy: original → text edits → form values → overlays → written in the work folder → moved to its
/// final name. The original is only ever read. Copies go next to the original as `Lease_signed.pdf`
/// (anything signed on it) or `Lease_edited.pdf`, through `OutputNaming.uniqueURL`; if that folder
/// can't be written (Mail attachments, read-only disks) the copy goes to the fallback folder instead.
enum SaveCopy {
    struct Request: Sendable {
        var original: URL
        var password: String?
        var textEdits: [TextEdit] = []
        /// Field name → value (text, "Off", or a checkbox/radio on-state).
        var formValues: [String: String] = [:]
        var overlays: [Overlay] = []
        var flatten = false
        /// The copy this tab saved before: later saves update that same file.
        var previousCopy: URL?
        /// The file that save wrote. If something else now sits at `previousCopy`, it's left alone.
        var previousCopyID: FileID?
        /// Save Copy As…: exactly this file (the person confirmed replacing it in the save dialog).
        var exactDestination: URL?
        /// Files that must never be written either: the originals of other open tabs.
        var protected: [URL] = []
        var fallbackFolder: URL
        var workDir: URL
    }

    struct Outcome: Sendable, Equatable {
        var url: URL
        /// True when the original's folder couldn't be written and the copy went to the fallback folder.
        var usedFallback: Bool
        /// The file just written, for `Request.previousCopyID` next time.
        var fileID: FileID?
    }

    /// A file's identity on disk (volume and inode), so a later save can tell its own copy from a file
    /// that was put at the same path since.
    struct FileID: Sendable, Equatable {
        let volume: Int
        let inode: Int

        static func of(_ url: URL) -> FileID? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let volume = (a[.systemNumber] as? NSNumber)?.intValue,
                  let inode = (a[.systemFileNumber] as? NSNumber)?.intValue else { return nil }
            return FileID(volume: volume, inode: inode)
        }
    }

    enum Failure: LocalizedError {
        case wouldReplaceOriginal
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .wouldReplaceOriginal: "Stitch never saves over the original. Choose another name."
            case .writeFailed(let detail): "Couldn't save the copy: \(detail)"
            }
        }
    }

    static func suffix(signed: Bool) -> String { signed ? "_signed" : "_edited" }

    static func defaultBaseName(for original: URL, signed: Bool) -> String {
        original.deletingPathExtension().lastPathComponent + suffix(signed: signed)
    }

    /// Builds the finished PDF in the work folder.
    static func render(_ r: Request) throws -> URL {
        let doc = try MuPDFDocument(url: r.original, password: r.password)
        try StampRenderer.apply(r.textEdits, to: doc, workDir: r.workDir)
        if !r.formValues.isEmpty {
            let names = (try? doc.fields().map(\.name)) ?? []
            for (name, value) in r.formValues.sorted(by: { $0.key < $1.key }) {
                guard let target = resolveFieldName(name, in: names) else { continue }
                try doc.setField(target, to: value)
            }
        }
        try StampRenderer.apply(r.overlays, to: doc, workDir: r.workDir)
        if r.flatten { try doc.bake() }
        let out = r.workDir.appendingPathComponent("save-\(UUID().uuidString).pdf")
        try doc.save(to: out)
        return out
    }

    static func run(_ r: Request) throws -> Outcome {
        let built = try render(r)
        defer { try? FileManager.default.removeItem(at: built) }
        let untouchable = [r.original] + r.protected
        func isOriginal(_ url: URL) -> Bool { untouchable.contains { sameFile($0, url) } }

        if let exact = r.exactDestination {
            guard !isOriginal(exact) else { throw Failure.wouldReplaceOriginal }
            try place(built, at: exact, replacing: true)
            return Outcome(url: exact, usedFallback: false, fileID: FileID.of(exact))
        }
        if let previous = r.previousCopy, !isOriginal(previous),
           FileManager.default.fileExists(atPath: previous.path),
           r.previousCopyID == nil || FileID.of(previous) == r.previousCopyID {
            do {
                try place(built, at: previous, replacing: true)
                return Outcome(url: previous, usedFallback: false, fileID: FileID.of(previous))
            } catch {
                // It was moved somewhere unwritable or deleted mid-save; fall through to a fresh name.
            }
        }
        let signed = r.overlays.contains(where: \.isSigning)
        let base = defaultBaseName(for: r.original, signed: signed)
        let folder = r.original.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: folder.path),
           let target = try? placeUnderFreshName(built, in: folder, base: base) {
            return Outcome(url: target, usedFallback: false, fileID: FileID.of(target))
        }
        let target = try placeUnderFreshName(built, in: r.fallbackFolder, base: base)
        return Outcome(url: target, usedFallback: true, fileID: FileID.of(target))
    }

    /// `base.pdf`, `base (2).pdf`…: never replaces anything, even a file that appears while saving.
    private static func placeUnderFreshName(_ built: URL, in folder: URL, base: String) throws -> URL {
        var lastError: Error = Failure.writeFailed("no free name")
        for _ in 0..<5 {
            let target = OutputNaming.uniqueURL(in: folder, base: base, ext: "pdf")
            do {
                try place(built, at: target, replacing: false)
                return target
            } catch {
                lastError = error
                guard FileManager.default.fileExists(atPath: target.path) else { throw error }
            }
        }
        throw lastError
    }

    /// Copies (never moves, so the built file stays for a retry) to `target`. Replaces what's there only
    /// with `replacing` (Save As, or this tab's own earlier copy); otherwise fails if the name is taken.
    private static func place(_ built: URL, at target: URL, replacing: Bool) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".stitch-\(UUID().uuidString).pdf")
        do {
            try fm.copyItem(at: built, to: staged)
            if replacing, fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)   // fails if the name was taken meanwhile
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// True when both name the same file on disk: same file identity (so "lease.pdf" on a case-insensitive
    /// disk, symlinks and hard links all count), or the same path, ignoring case, when one doesn't exist.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        // Resource values describe a symlink itself, not what it points to: resolve both first.
        let a = a.standardizedFileURL.resolvingSymlinksInPath(), b = b.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let ia = (try? a.resourceValues(forKeys: keys))?.fileResourceIdentifier,
           let ib = (try? b.resourceValues(forKeys: keys))?.fileResourceIdentifier {
            return ia.isEqual(ib)
        }
        let pa = a.standardizedFileURL.resolvingSymlinksInPath().path, pb = b.standardizedFileURL.resolvingSymlinksInPath().path
        return pa.caseInsensitiveCompare(pb) == .orderedSame
    }

    /// PDFKit sometimes reports a field's last name part ("City") where MuPDF has the full name
    /// ("Address.City"); match exactly first, then by a unique suffix.
    static func resolveFieldName(_ name: String, in names: [String]) -> String? {
        if names.contains(name) { return name }
        let matches = Set(names.filter { $0.hasSuffix("." + name) })
        return matches.count == 1 ? matches.first : nil
    }
}
