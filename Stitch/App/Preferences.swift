import Foundation
import Observation

/// Settings, saved in UserDefaults as they change.
@MainActor
@Observable
final class Preferences {
    static let targetChoices = [10, 20, 25, 30, 50, 100, 200]

    @ObservationIgnored private let defaults: UserDefaults

    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    /// Upload size target in MB (1 MB = 1,000,000 bytes, as Finder counts).
    var targetMB: Int { didSet { defaults.set(targetMB, forKey: Key.targetMB) } }
    /// Off by default for speed; remembers the last setting.
    var ocr: Bool { didSet { defaults.set(ocr, forKey: Key.ocr) } }
    var shrink: Bool { didSet { defaults.set(shrink, forKey: Key.shrink) } }
    /// Convert to PDF: all images into one PDF instead of one PDF each.
    var combineImages: Bool { didSet { defaults.set(combineImages, forKey: Key.combineImages) } }
    var stripLocation: Bool { didSet { defaults.set(stripLocation, forKey: Key.stripLocation) } }
    var libreOfficeNoticeShown: Bool { didSet { defaults.set(libreOfficeNoticeShown, forKey: Key.libreOfficeNoticeShown) } }

    var targetBytes: Int64 { Int64(targetMB) * 1_000_000 }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.targetMB: 30, Key.ocr: false, Key.shrink: true, Key.combineImages: false, Key.stripLocation: true,
        ])
        let folder = defaults.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        var isDir: ObjCBool = false
        if let folder, FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
            saveFolder = folder
        } else {
            saveFolder = Self.downloads
        }
        targetMB = defaults.integer(forKey: Key.targetMB)
        ocr = defaults.bool(forKey: Key.ocr)
        shrink = defaults.bool(forKey: Key.shrink)
        combineImages = defaults.bool(forKey: Key.combineImages)
        stripLocation = defaults.bool(forKey: Key.stripLocation)
        libreOfficeNoticeShown = defaults.bool(forKey: Key.libreOfficeNoticeShown)
    }

    private enum Key {
        static let saveFolder = "saveFolder"
        static let targetMB = "targetMB"
        static let ocr = "ocr"
        static let shrink = "shrink"
        static let combineImages = "combineImages"
        static let stripLocation = "stripLocation"
        static let libreOfficeNoticeShown = "libreOfficeNoticeShown"
    }
}
