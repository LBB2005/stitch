import AppKit
import PDFKit
import QuickLookThumbnailing

/// CGImage is immutable and safe to share; this lets it cross actors.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Page thumbnails for the Arrange grid, rendered off the main thread and cached.
actor ThumbnailStore {
    static let shared = ThumbnailStore()

    private var docs: [URL: PDFDocument] = [:]
    private var cache: [String: SendableImage] = [:]

    func page(_ url: URL, index: Int, maxSide: CGFloat) -> SendableImage? {
        let key = "\(url.path)#\(index)@\(Int(maxSide))"
        if let hit = cache[key] { return hit }
        let doc = docs[url] ?? PDFDocument(url: url)
        docs[url] = doc
        guard let page = doc?.page(at: index) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = maxSide / max(size.width, size.height, 1)
        let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result = SendableImage(cgImage: cg)
        cache[key] = result
        return result
    }

    func reset() {
        docs = [:]
        cache = [:]
    }
}

/// Finder-style thumbnails for the file list (a photo's picture, a PDF's first page, a Word icon).
enum FileThumbnail {
    static func load(_ url: URL, side: CGFloat, scale: CGFloat) async -> SendableImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .all)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep.map { SendableImage(cgImage: $0.cgImage) })
            }
        }
    }
}
