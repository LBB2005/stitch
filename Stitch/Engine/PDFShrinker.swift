import CoreGraphics
import Foundation
import PDFKit
import Quartz

/// Shrink to fit an upload limit, quality first: only embedded images are resampled and re-encoded
/// (text and vector content is redrawn exactly as it was), one step at a time, stopping at the first
/// step that fits. It never goes below 150 DPI or JPEG quality 0.75.
enum PDFShrinker {
    struct Step: Equatable, Sendable {
        let dpi: Int
        let quality: Double
    }

    static let ladder = [Step(dpi: 300, quality: 0.85), Step(dpi: 220, quality: 0.8), Step(dpi: 150, quality: 0.75)]

    enum Outcome: Sendable {
        /// Already under the target; nothing was written.
        case fits
        case shrunk(URL, Step)
        /// Even the last step is over the target. `best` is that last (smallest) version.
        case tooBig(best: URL, Step)
    }

    /// Tries each step in turn. Results are written into `workDir`.
    static func fit(_ src: URL, target: Int64, workDir: URL, onStep: (Step) -> Void) throws -> Outcome {
        guard PDFTools.size(src) > target else { return .fits }
        var last: (URL, Step)?
        for step in ladder {
            try Task.checkCancellation()
            onStep(step)
            let out = workDir.appendingPathComponent("shrunk-\(step.dpi)-\(UUID().uuidString).pdf")
            try render(src, step: step, to: out)
            if PDFTools.size(out) <= target { return .shrunk(out, step) }
            last = (out, step)
        }
        return .tooBig(best: last!.0, last!.1)
    }

    /// Redraws every page through a Quartz filter that downsamples images above `step.dpi` and stores them
    /// as JPEG at `step.quality`. Links are put back afterwards; bookmarks are added by the caller.
    static func render(_ src: URL, step: Step, to dst: URL) throws {
        guard let doc = CGPDFDocument(src as CFURL) else { throw PDFTools.Failure.unreadable(src.lastPathComponent) }
        var box = CGRect.zero
        guard let ctx = CGContext(dst as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Stitch"] as CFDictionary),
              let filter = QuartzFilter(properties: filterProperties(step)), filter.apply(to: ctx) else {
            throw PDFTools.Failure.writeFailed
        }
        for i in 0..<doc.numberOfPages {
            try Task.checkCancellation()
            guard let page = doc.page(at: i + 1) else { continue }
            ctx.beginPDFPage(PDFTools.pageInfo(size: PDFTools.displaySize(of: page)))
            PDFTools.draw(page, in: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try restoreLinks(from: src, to: dst)
    }

    static func filterProperties(_ step: Step) -> [String: Any] {
        [
            "Domains": ["Applications": true],
            "FilterType": 1,
            "Name": "Stitch \(step.dpi) DPI",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": step.quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": step.dpi,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 100_000,
                            "ImageSizeMin": 0,
                        ] as [String: Any],
                    ] as [String: Any],
                ],
            ],
        ]
    }

    /// Redrawing drops annotations; copy the links back onto the upright pages they came from.
    private static func restoreLinks(from src: URL, to dst: URL) throws {
        guard let original = PDFDocument(url: src), let shrunk = PDFDocument(url: dst) else { return }
        var added = false
        for i in 0..<min(original.pageCount, shrunk.pageCount) {
            guard let from = original.page(at: i), let to = shrunk.page(at: i), from.rotation == 0 else { continue }
            let origin = from.bounds(for: .cropBox).origin
            for annotation in from.annotations where annotation.type == "Link" {
                let link = PDFAnnotation(bounds: annotation.bounds.offsetBy(dx: -origin.x, dy: -origin.y),
                                         forType: .link, withProperties: nil)
                if let url = annotation.url {
                    link.url = url
                } else if let dest = annotation.destination, let page = dest.page,
                          let target = shrunk.page(at: original.index(for: page)) {
                    link.destination = PDFDestination(page: target, at: dest.point)
                } else { continue }
                let border = PDFBorder()
                border.lineWidth = 0
                link.border = border
                to.addAnnotation(link)
                added = true
            }
        }
        if added { guard shrunk.write(to: dst) else { throw PDFTools.Failure.writeFailed } }
    }

    // MARK: split

    /// Splits into parts that each fit under `target`, named `base – Part 1 of 3.pdf` in `folder`.
    static func split(_ src: URL, target: Int64, folder: URL, base: String) throws -> [URL] {
        let doc = try PDFTools.open(src)
        // Each page alone, which over-counts shared fonts, so parts come out a little under budget.
        let estimates: [Int64] = (0..<doc.pageCount).map { i in
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            return Int64(single.dataRepresentation()?.count ?? 0)
        }
        let budget = Int64(Double(target) * 0.95)
        var groups: [[Int]] = []
        var current: [Int] = []
        var used: Int64 = 0
        for (i, size) in estimates.enumerated() {
            if !current.isEmpty, used + size > budget {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(i)
            used += size
        }
        if !current.isEmpty { groups.append(current) }

        // Write each part; one still over the target is halved until it fits or is a single page.
        var parts: [Data] = []
        var queue = groups
        while !queue.isEmpty {
            try Task.checkCancellation()
            let group = queue.removeFirst()
            let part = PDFDocument()
            for i in group { if let page = doc.page(at: i)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) } }
            guard let data = part.dataRepresentation() else { throw PDFTools.Failure.writeFailed }
            if Int64(data.count) > target, group.count > 1 {
                let mid = group.count / 2
                queue.insert(contentsOf: [Array(group[..<mid]), Array(group[mid...])], at: 0)
            } else {
                parts.append(data)
            }
        }

        var urls: [URL] = []
        for (n, data) in parts.enumerated() {
            let url = OutputNaming.uniqueURL(in: folder, base: "\(base) – Part \(n + 1) of \(parts.count)", ext: "pdf")
            try data.write(to: url, options: .withoutOverwriting)
            urls.append(url)
        }
        return urls
    }
}
