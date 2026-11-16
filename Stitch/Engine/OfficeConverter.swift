import Foundation

/// Word, PowerPoint and Excel → PDF through LibreOffice (`soffice --headless --convert-to pdf`). macOS has no
/// converter of its own, so these files are skipped when LibreOffice isn't installed.
enum OfficeConverter {
    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "LibreOffice isn't installed."
            case .failed(let name): "LibreOffice couldn't convert \(name)."
            case .timedOut(let name): "LibreOffice took too long to convert \(name)."
            }
        }
    }

    static let installHelpURL = URL(string: "https://www.libreoffice.org/download/download-libreoffice/")!
    static let brewCommand = "brew install --cask libreoffice"
    static let timeout: TimeInterval = 180

    static var sofficeURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "\(home)/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static var isInstalled: Bool { sofficeURL != nil }

    /// LibreOffice's own settings for Stitch, kept apart from the person's so a LibreOffice window that is
    /// already open doesn't block the conversion. Kept in Caches so its first-run setup happens once.
    private static var profileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.liamblackshawbrown.Stitch/LibreOfficeProfile", isDirectory: true)
    }

    /// Converts a copy of the file (LibreOffice can leave lock files next to what it opens, and the
    /// original must not be touched) and returns the new PDF. With `fitSheetsToWidth`, every sheet of a
    /// workbook is printed one page wide (landscape when it's wider than a portrait page); if that fails,
    /// it falls back to the workbook's own print layout.
    static func convert(_ src: URL, workDir: URL, fitSheetsToWidth: Bool = false) async throws -> URL {
        guard let soffice = sofficeURL else { throw Failure.notInstalled }
        let dir = workDir.appendingPathComponent("office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: copy)
        let out = dir.appendingPathComponent(copy.deletingPathExtension().lastPathComponent + ".pdf")
        try? lockDownProfile()
        let common = ["-env:UserInstallation=\(profileURL.absoluteString)",
                      "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck"]

        if fitSheetsToWidth, (try? installFitScript()) != nil {
            let process = Process()
            confine(process, soffice: soffice,
                    arguments: common + ["vnd.sun.star.script:\(fitScriptName)$fit_to_width?language=Python&location=user"],
                    extra: ["STITCH_SRC": copy.path, "STITCH_OUT": out.path])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if try await run(ProcessBox(process), name: src.lastPathComponent),
               FileManager.default.fileExists(atPath: out.path) {
                return out
            }
        }

        let process = Process()
        confine(process, soffice: soffice, arguments: common + ["--convert-to", "pdf", "--outdir", dir.path, copy.path])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = try await run(ProcessBox(process), name: src.lastPathComponent)
        guard finished, FileManager.default.fileExists(atPath: out.path) else {
            throw Failure.failed(src.lastPathComponent)
        }
        return out
    }

    // MARK: keeping LibreOffice local and macro-free

    /// Documents are someone else's files: LibreOffice runs with no internet access (no remote images,
    /// links or WEBSERVICE() calls can phone home), only the environment it needs, and the profile set to
    /// run no document macros and follow no untrusted links.
    private static func confine(_ process: Process, soffice: URL, arguments: [String], extra: [String: String] = [:]) {
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        if FileManager.default.isExecutableFile(atPath: sandbox.path) {
            process.executableURL = sandbox
            process.arguments = ["-p", noNetworkProfile, soffice.path] + arguments
        } else {
            process.executableURL = soffice
            process.arguments = arguments
        }
        let env = ProcessInfo.processInfo.environment
        var keep: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = env[key] { keep[key] = value }
        }
        process.environment = keep.merging(extra) { $1 }
    }

    /// Everything allowed except internet (IP) connections; local sockets LibreOffice uses for itself still work.
    static let noNetworkProfile = "(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound (local ip))"

    /// Settings Stitch forces in its own LibreOffice profile, merged into `registrymodifications.xcu`.
    static let lockedSettings: [(path: String, name: String, type: String, value: String)] = [
        // Very high: document macros never run (Stitch's own script lives in the profile, a trusted place).
        ("/org.openoffice.Office.Common/Security/Scripting", "MacroSecurityLevel", "int", "3"),
        ("/org.openoffice.Office.Common/Security/Scripting", "BlockUntrustedRefererLinks", "boolean", "true"),
    ]

    private static func lockDownProfile() throws {
        let dir = profileURL.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("registrymodifications.xcu")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let merged = lockedRegistry(existing)
        if merged != existing { try Data(merged.utf8).write(to: file, options: .atomic) }
    }

    /// `xcu` with Stitch's locked settings in it, replacing any older values for the same settings.
    static func lockedRegistry(_ xcu: String) -> String {
        let footer = "</oor:items>"
        var text = xcu
        if !text.contains(footer) {
            text = """
                <?xml version="1.0" encoding="UTF-8"?>
                <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                </oor:items>

                """
        }
        var lines = text.components(separatedBy: "\n")
        for s in lockedSettings {
            lines.removeAll { $0.contains("oor:path=\"\(s.path)\"") && $0.contains("oor:name=\"\(s.name)\"") }
        }
        let items = lockedSettings.map { s in
            "<item oor:path=\"\(s.path)\"><prop oor:name=\"\(s.name)\" oor:op=\"fuse\"><value>\(s.value)</value></prop></item>"
        }
        if let end = lines.lastIndex(where: { $0.contains(footer) }) { lines.insert(contentsOf: items, at: end) }
        return lines.joined(separator: "\n")
    }

    // MARK: fitting sheets to the page width

    private static let fitScriptName = "stitch_fit.py"

    /// A LibreOffice Python macro, kept in Stitch's own profile: opens the workbook named in STITCH_SRC,
    /// sets every sheet to print one page wide (turning it landscape when its columns are wider than a
    /// portrait page), and exports the PDF to STITCH_OUT. `--convert-to` has no option for this.
    private static let fitScript = """
        import os
        import uno
        from com.sun.star.beans import PropertyValue


        def _prop(name, value):
            p = PropertyValue()
            p.Name = name
            p.Value = value
            return p


        def fit_to_width(*args):
            desktop = XSCRIPTCONTEXT.getDesktop()
            src, out = os.environ["STITCH_SRC"], os.environ["STITCH_OUT"]
            # Never run the workbook's own macros, never refresh its external links (both 0 = never).
            doc = desktop.loadComponentFromURL(uno.systemPathToFileUrl(src), "_blank", 0,
                                               (_prop("Hidden", True), _prop("MacroExecutionMode", 0),
                                                _prop("UpdateDocMode", 0)))
            try:
                styles = doc.StyleFamilies.getByName("PageStyles")
                for sheet in doc.Sheets:
                    style = styles.getByName(sheet.PageStyle)
                    style.ScaleToPagesX = 1
                    style.ScaleToPagesY = 0
                    cursor = sheet.createCursor()
                    cursor.gotoEndOfUsedArea(False)
                    columns = sheet.Columns
                    used = sum(columns.getByIndex(i).Width for i in range(cursor.RangeAddress.EndColumn + 1)
                               if columns.getByIndex(i).IsVisible)
                    short, long = sorted((style.Width, style.Height))
                    if used > short - style.LeftMargin - style.RightMargin:
                        style.IsLandscape = True
                        style.Width, style.Height = long, short
                doc.storeToURL(uno.systemPathToFileUrl(out), (_prop("FilterName", "calc_pdf_Export"),))
            finally:
                doc.close(True)

        """

    /// Writes the macro into the profile every time, so an updated Stitch replaces an older copy.
    private static func installFitScript() throws {
        let dir = profileURL.appendingPathComponent("user/Scripts/python", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(fitScript.utf8).write(to: dir.appendingPathComponent(fitScriptName), options: .atomic)
    }

    /// Runs the process to the end; cancelling the task or hitting the timeout terminates it.
    private static func run(_ box: ProcessBox, name: String) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                box.process.terminationHandler = { p in
                    if box.timedOut {
                        cont.resume(throwing: Failure.timedOut(name))
                    } else {
                        cont.resume(returning: p.terminationStatus == 0)
                    }
                }
                do {
                    try box.process.run()
                } catch {
                    box.process.terminationHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard box.process.isRunning else { return }
                    box.timedOut = true
                    box.process.terminate()
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}

/// `Process` isn't Sendable; it is only touched to start, check and terminate it, which are thread-safe.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    var timedOut = false
    init(_ process: Process) { self.process = process }
}
