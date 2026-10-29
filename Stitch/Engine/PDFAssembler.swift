import CoreGraphics
import Foundation
import PDFKit

/// A source ready to merge: the original PDF, or a temporary PDF made from an image or Office file.
struct PreparedFile: Sendable, Equatable {
    let fileID: UUID
    let pdfURL: URL
    let pageCount: Int
    let title: String
}

/// A bookmark in the merged PDF: one per source file, pointing at its first page.
struct OutlineEntry: Sendable, Equatable {
    let title: String
    let pageIndex: Int
}

enum PDFTools {
    enum Failure: LocalizedError {
        case unreadable(String)
        case locked(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)."
            case .locked(let name): "\(name) is password-protected."
            case .writeFailed: "Couldn't write the PDF."
            }
        }
    }

    static func open(_ url: URL, name: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable(name ?? url.lastPathComponent) }
        if doc.isLocked { throw Failure.locked(name ?? url.lastPathComponent) }
        return doc
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
    }

    /// Copies the pages, in this order, into one new PDF. Returns a bookmark per source file at its first
    /// page (added at the very end, after OCR and shrinking, which would otherwise drop them).
    static func assemble(_ pages: [PageRef], sources: [UUID: PreparedFile], to dst: URL) throws -> [OutlineEntry] {
        var docs: [UUID: PDFDocument] = [:]
        let out = PDFDocument()
        var outline: [OutlineEntry] = []
        var seen = Set<UUID>()
        for ref in pages {
            try Task.checkCancellation()
            guard let source = sources[ref.fileID] else { continue }
            let doc: PDFDocument
            if let open = docs[ref.fileID] {
                doc = open
            } else {
                doc = try open(source.pdfURL, name: source.title)
                docs[ref.fileID] = doc
            }
            guard let page = doc.page(at: ref.index)?.copy() as? PDFPage else { continue }
            if seen.insert(ref.fileID).inserted {
                outline.append(OutlineEntry(title: source.title, pageIndex: out.pageCount))
            }
            out.insert(page, at: out.pageCount)
        }
        guard out.write(to: dst) else { throw Failure.writeFailed }
        return outline.count >= 2 ? outline : []
    }

    /// Writes a copy of `src` with the bookmarks added.
    static func addOutline(_ entries: [OutlineEntry], to src: URL, writingTo dst: URL) throws {
        let doc = try open(src)
        let root = PDFOutline()
        for (i, entry) in entries.enumerated() {
            guard let page = doc.page(at: entry.pageIndex) else { continue }
            let item = PDFOutline()
            item.label = entry.title
            let box = page.bounds(for: .cropBox)
            item.destination = PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY))
            root.insertChild(item, at: i)
        }
        doc.outlineRoot = root
        guard doc.write(to: dst) else { throw Failure.writeFailed }
    }

    // MARK: page geometry

    /// The page as it is displayed: crop box with its rotation applied.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let crop = page.getBoxRect(.cropBox)
        let quarterTurns = ((Int(page.rotationAngle) % 360) + 360) % 360 / 90
        return quarterTurns % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    /// Maps the page's content onto an upright `(0, 0, size)` page, applying its rotation and crop.
    static func drawingTransform(for page: CGPDFPage) -> CGAffineTransform {
        let size = displaySize(of: page)
        return page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
    }

    /// Draws the page's content upright into the current page of `ctx` (vectors and text stay vectors and text).
    static func draw(_ page: CGPDFPage, in ctx: CGContext) {
        ctx.saveGState()
        ctx.concatenate(drawingTransform(for: page))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    static func pageInfo(size: CGSize) -> CFDictionary {
        var box = CGRect(origin: .zero, size: size)
        return [kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
    }
}
