import Foundation

/// Stitch's scratch space for intermediate files (and the working copies of open PDFs). Never holds the
/// person's originals or outputs. It lives in this Mac user's own temp folder, and each running copy of
/// Stitch gets its own folder inside it (named by process ID), so a second copy — the Debug build, the
/// test host — never deletes the files an open document window is using.
enum Workspace {
    static let base = FileManager.default.temporaryDirectory.appendingPathComponent("Stitch", isDirectory: true)
    static let root = base.appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)

    static func makeJobDir() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ dir: URL?) {
        guard let dir, dir.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// This copy of Stitch's scratch files (on quit).
    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Scratch folders left by copies of Stitch that have quit or crashed (at launch). Folders of copies
    /// still running are kept.
    static func clearLeftovers(in folder: URL = base, isRunning: (pid_t) -> Bool = processIsRunning) {
        let own = root.lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != own {
            if let pid = pid_t(item.lastPathComponent), isRunning(pid) { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func processIsRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
