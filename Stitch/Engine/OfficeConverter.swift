import Foundation

/// Word and PowerPoint → PDF through LibreOffice (`soffice --headless --convert-to pdf`). macOS has no
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
    /// original must not be touched) and returns the new PDF.
    static func convert(_ src: URL, workDir: URL) async throws -> URL {
        guard let soffice = sofficeURL else { throw Failure.notInstalled }
        let dir = workDir.appendingPathComponent("office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: copy)

        let process = Process()
        process.executableURL = soffice
        process.arguments = [
            "-env:UserInstallation=\(profileURL.absoluteString)",
            "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck",
            "--convert-to", "pdf", "--outdir", dir.path, copy.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = try await run(ProcessBox(process), name: src.lastPathComponent)
        let out = dir.appendingPathComponent(copy.deletingPathExtension().lastPathComponent + ".pdf")
        guard finished, FileManager.default.fileExists(atPath: out.path) else {
            throw Failure.failed(src.lastPathComponent)
        }
        return out
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
