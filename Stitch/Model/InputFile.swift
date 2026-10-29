import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What Stitch can do with a file, decided from its extension.
enum FileKind: Sendable, Equatable {
    case pdf
    case image(jpeg: Bool)
    case word
    case powerpoint

    static let wordExtensions: Set<String> = ["doc", "docx", "docm", "dot", "dotx", "odt", "rtf"]
    static let powerpointExtensions: Set<String> = ["ppt", "pptx", "pptm", "pps", "ppsx", "odp"]

    /// Image types ImageIO can decode on this Mac (HEIC, JPEG, PNG, TIFF, WebP, …).
    private static let readableImageTypes: Set<String> = {
        let ids = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return Set(ids)
    }()

    static func classify(_ url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if wordExtensions.contains(ext) { return .word }
        if powerpointExtensions.contains(ext) { return .powerpoint }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image), readableImageTypes.contains(type.identifier) {
            return .image(jpeg: type.conforms(to: .jpeg))
        }
        return nil
    }

    /// Every type the Choose Files… picker offers.
    static var pickerTypes: [UTType] {
        let office = (wordExtensions.union(powerpointExtensions)).compactMap { UTType(filenameExtension: $0) }
        return [.pdf, .image] + office
    }

    var isImage: Bool { if case .image = self { true } else { false } }
    var isOffice: Bool { self == .word || self == .powerpoint }
    var isPDF: Bool { self == .pdf }
}

/// A file the person added. Stitch only ever reads it.
struct InputFile: Identifiable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let kind: FileKind
    let bytes: Int64
    /// Pages in a PDF; nil for other kinds until they are converted.
    let pageCount: Int?

    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }

    init(id: UUID = UUID(), url: URL, kind: FileKind, bytes: Int64, pageCount: Int?) {
        self.id = id
        self.url = url
        self.kind = kind
        self.bytes = bytes
        self.pageCount = pageCount
    }

    /// Reads size and page count; nil if the type isn't supported.
    static func load(_ url: URL) -> InputFile? {
        guard let kind = FileKind.classify(url) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        var pages: Int?
        if kind == .pdf {
            pages = CGPDFDocument(url as CFURL)?.numberOfPages
        } else if kind.isImage {
            pages = 1
        }
        return InputFile(url: url, kind: kind, bytes: Int64(size), pageCount: pages)
    }
}

enum ByteSize {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
