import CoreGraphics
import Foundation

/// Draws new content (edited text, signatures, text boxes) with CoreText/CoreGraphics into tiny one-page
/// PDFs in the work folder, then has MuPDF place each one on its page as a Form XObject. Fonts embed
/// automatically and signatures stay vectors.
enum StampRenderer {
    enum Failure: LocalizedError {
        case couldNotDraw

        var errorDescription: String? { "Couldn't draw the new content." }
    }

    /// A one-page PDF of `size` (y up) drawn by `body`.
    static func write(size: CGSize, to url: URL, _ body: (CGContext) -> Void) throws {
        var box = CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw Failure.couldNotDraw }
        ctx.beginPDFPage(nil)
        body(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Removes each block's old text and stamps its new text in its place.
    static func apply(_ edits: [TextEdit], to doc: MuPDFDocument, workDir: URL) throws {
        var infos: [Int: MuPDFDocument.PageInfo] = [:]
        for edit in edits {
            try Task.checkCancellation()
            let info = try infos[edit.page] ?? doc.pageInfo(edit.page)
            infos[edit.page] = info
            try doc.removeText(onPage: edit.page, in: edit.block.removalRects)
            let laid = TextLayout.layout(edit)
            guard laid.lines.contains(where: { !$0.text.isEmpty }) else { continue }
            let url = workDir.appendingPathComponent("text-\(edit.id.uuidString).pdf")
            try write(size: laid.rect.size, to: url) { ctx in
                TextLayout.draw(laid, fontName: edit.block.fontName, color: edit.block.color, in: ctx)
            }
            try doc.place(url, onPage: edit.page,
                          transform: PageGeometry.stampTransform(forDisplayRect: laid.rect, toUserSpace: info.toUserSpace))
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stamps each overlay onto its page. A text box with a white background covers what's under it, so
    /// that content (text, scan pixels, drawings) is removed from the file first, not just painted over.
    static func apply(_ overlays: [Overlay], to doc: MuPDFDocument, workDir: URL) throws {
        for overlay in overlays {
            try Task.checkCancellation()
            if case .text(let box) = overlay.kind, box.text.isEmpty, !box.whiteBackground { continue }
            if case .text(let box) = overlay.kind, box.whiteBackground {
                let info = try doc.pageInfo(overlay.page)
                try doc.redact(onPage: overlay.page, in: [overlay.rect.applying(info.toDisplay)], images: true, lineArt: true)
            }
            let url = workDir.appendingPathComponent("overlay-\(overlay.id.uuidString).pdf")
            try write(size: overlay.uprightSize, to: url) { overlay.drawContent(in: $0) }
            try doc.place(url, onPage: overlay.page,
                          transform: PageGeometry.uprightTransform(for: overlay.rect, rotation: overlay.rotation))
            try? FileManager.default.removeItem(at: url)
        }
    }
}
