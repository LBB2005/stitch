import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// "Make scans searchable": recognises text on pages that have none and adds it as an invisible layer,
/// so the page looks exactly the same but can be searched, selected and read by an AI.
enum OCRService {
    struct Line {
        let text: String
        /// Normalised (0…1) box, origin bottom-left, in the upright page.
        let box: CGRect
    }

    /// Pages with fewer than this many non-space characters count as having no text layer.
    static let minimumTextCharacters = 4

    static func needsOCR(_ page: PDFPage) -> Bool {
        let text = page.string ?? ""
        return text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count < minimumTextCharacters
    }

    /// Writes `dst` with text added to every page that needs it; returns how many pages were recognised.
    /// When no page needs it, `dst` is a plain copy.
    @discardableResult
    static func makeSearchable(_ src: URL, to dst: URL, progress: (Int, Int) -> Void) throws -> Int {
        let doc = try PDFTools.open(src)
        let targets = (0..<doc.pageCount).filter { doc.page(at: $0).map(needsOCR) ?? false }
        guard !targets.isEmpty else {
            try FileManager.default.copyItem(at: src, to: dst)
            return 0
        }
        for (n, index) in targets.enumerated() {
            try Task.checkCancellation()
            progress(n + 1, targets.count)
            guard let page = doc.page(at: index), let cgPage = page.pageRef,
                  let image = render(cgPage) else { continue }
            let lines = try recognize(image)
            guard !lines.isEmpty, let replacement = searchablePage(cgPage, lines: lines) else { continue }
            doc.removePage(at: index)
            doc.insert(replacement, at: index)
        }
        guard doc.write(to: dst) else { throw PDFTools.Failure.writeFailed }
        return targets.count
    }

    // MARK: steps

    /// The upright page at up to 300 DPI (capped at 4000 px on the long side), on white.
    static func render(_ page: CGPDFPage) -> CGImage? {
        let size = PDFTools.displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(300.0 / 72.0, 4000 / max(size.width, size.height))
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        PDFTools.draw(page, in: ctx)
        return ctx.makeImage()
    }

    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Line(text: text, box: obs.boundingBox)
        }
    }

    /// A new, upright page: the original content drawn unchanged, with the recognised lines on top in
    /// invisible text, each stretched to cover the words it was read from so selection lines up.
    static func searchablePage(_ page: CGPDFPage, lines: [Line]) -> PDFPage? {
        let size = PDFTools.displaySize(of: page)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "Stitch"] as CFDictionary)
        else { return nil }
        ctx.beginPDFPage(PDFTools.pageInfo(size: size))
        PDFTools.draw(page, in: ctx)

        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                              width: line.box.width * size.width, height: line.box.height * size.height)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            // Measure at a natural size, then stretch the font itself (not the text matrix, whose glyph
            // gaps read back as spaces: "M itochondria") so the line spans the words it was read from.
            let fontSize = rect.height * 0.8
            let natural = invisibleLine(line.text, font: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil))
            let width = CTLineGetTypographicBounds(natural, nil, nil, nil)
            guard width > 0 else { continue }
            var stretch = CGAffineTransform(scaleX: rect.width / width, y: 1)
            let ctLine = invisibleLine(line.text, font: CTFontCreateWithName("Helvetica" as CFString, fontSize, &stretch))
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(ctLine, nil, &descent, nil)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent)
            CTLineDraw(ctLine, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let newPage = doc.page(at: 0) else { return nil }
        return newPage.copy() as? PDFPage
    }

    /// No kerning or ligatures, so the text reads back exactly as recognised.
    private static func invisibleLine(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): 0,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ]))
    }
}
