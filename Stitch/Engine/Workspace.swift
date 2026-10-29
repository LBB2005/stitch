import Foundation

/// Stitch's scratch space for intermediate files. Never holds the person's originals or outputs.
enum Workspace {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Stitch", isDirectory: true)

    static func makeJobDir() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ dir: URL?) {
        guard let dir, dir.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
