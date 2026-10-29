import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Stitch

final class ImageConverterTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() { fx.cleanUp() }

    private func properties(_ url: URL) -> [CFString: Any] {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    }

    func testHEICToJPEGKeepsOrientationAndStripsLocation() throws {
        // Stored 400×300 with "rotate 90° CW" (6): upright it is 300×400.
        let heic = fx.image("IMG_0001.HEIC", type: .heic, orientation: 6, gps: true)
        let before = try fx.digest(heic)
        let out = fx.url("out.jpg")
        try ImageConverter.writeJPEG(from: heic, to: out, stripLocation: true)

        let props = properties(out)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 300)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 400)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifLensModel] as? String, "Test Lens", "other metadata is kept")
        XCTAssertEqual(try fx.digest(heic), before, "original untouched")
    }

    func testLocationKeptWhenAsked() throws {
        let heic = fx.image("IMG_0002.HEIC", type: .heic, gps: true)
        let out = fx.url("out.jpg")
        try ImageConverter.writeJPEG(from: heic, to: out, stripLocation: false)
        XCTAssertNotNil(properties(out)[kCGImagePropertyGPSDictionary])
    }

    func testTransparentPNGBecomesWhiteNotBlack() throws {
        let png = fx.image("logo.png", type: .png, alpha: true)
        let out = fx.url("logo.jpg")
        try ImageConverter.writeJPEG(from: png, to: out, stripLocation: true)
        let image = try ImageConverter.load(out).image
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Bottom-right pixel was transparent.
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width - 1), y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(px[0], 240)
        XCTAssertGreaterThan(px[2], 240)
    }

    func testImagesToPDFOnePagePerImageSizedToImage() throws {
        let wide = fx.image("wide.png", type: .png, width: 400, height: 200)
        let rotated = fx.image("rotated.heic", type: .heic, width: 400, height: 300, orientation: 6)
        let huge = fx.image("huge.jpg", type: .jpeg, width: 4000, height: 3000)
        let out = fx.url("images.pdf")
        try ImageConverter.writePDF(images: [wide, rotated, huge], to: out)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 200))
        XCTAssertEqual(doc.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 400))
        XCTAssertEqual(doc.page(at: 2)?.bounds(for: .mediaBox).size, CGSize(width: 842, height: 632), "capped to A4's long side")
    }

    func testUprightJPEGIsEmbeddedWithoutReencoding() throws {
        let photo = fx.url("photo.jpg")
        let image = fx.noise(width: 1600, height: 1200)
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let out = fx.url("photo.pdf")
        try ImageConverter.writePDF(images: [photo], to: out)
        let jpegSize = PDFTools.size(photo), pdfSize = PDFTools.size(out)
        XCTAssertLessThan(pdfSize, jpegSize + 20_000, "the JPEG data is passed through, not inflated")
    }
}

final class PDFEngineTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() { fx.cleanUp() }

    private func prepared(_ url: URL, title: String) -> PreparedFile {
        PreparedFile(fileID: UUID(), pdfURL: url, pageCount: PDFDocument(url: url)!.pageCount, title: title)
    }

    func testAssembleFollowsPageOrderAndBookmarksEachFile() throws {
        let a = prepared(fx.textPDF("a.pdf", pages: 2, label: "Alpha"), title: "Alpha")
        let b = prepared(fx.textPDF("b.pdf", pages: 3, label: "Beta"), title: "Beta")
        let pages = [PageRef(fileID: b.fileID, index: 2), PageRef(fileID: a.fileID, index: 0),
                     PageRef(fileID: b.fileID, index: 0), PageRef(fileID: a.fileID, index: 1)]
        let out = fx.url("merged.pdf")
        let outline = try PDFTools.assemble(pages, sources: [a.fileID: a, b.fileID: b], to: out)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 4)
        let texts = (0..<4).map { doc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(texts, ["Beta page 3", "Alpha page 1", "Beta page 1", "Alpha page 2"])
        XCTAssertEqual(outline, [OutlineEntry(title: "Beta", pageIndex: 0), OutlineEntry(title: "Alpha", pageIndex: 1)])

        let outlined = fx.url("outlined.pdf")
        try PDFTools.addOutline(outline, to: out, writingTo: outlined)
        let root = try XCTUnwrap(PDFDocument(url: outlined)?.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 2)
        XCTAssertEqual(root.child(at: 1)?.label, "Alpha")
    }

    func testShrinkLeavesFilesUnderTheLimitAlone() throws {
        let src = fx.textPDF("small.pdf", pages: 2, label: "Small")
        let outcome = try PDFShrinker.fit(src, target: 30_000_000, workDir: fx.dir) { _ in }
        guard case .fits = outcome else { return XCTFail("expected .fits, got \(outcome)") }
    }

    func testShrinkStopsAtFirstStepThatFitsAndKeepsText() throws {
        let src = fx.heavyPDF("heavy.pdf", pages: 3)
        let original = PDFTools.size(src)
        var steps: [Int] = []
        let outcome = try PDFShrinker.fit(src, target: original / 3, workDir: fx.dir) { steps.append($0.dpi) }
        guard case .shrunk(let url, let step) = outcome else { return XCTFail("expected .shrunk, got \(outcome)") }
        XCTAssertEqual(steps.first, 300)
        XCTAssertEqual(steps.last, step.dpi, "stops at the first step that fits")
        XCTAssertLessThanOrEqual(PDFTools.size(url), original / 3)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(doc.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Heavy page 2")
    }

    func testShrinkNeverGoesBelow150DPI() throws {
        let src = fx.heavyPDF("heavy.pdf", pages: 2)
        var steps: [Int] = []
        let outcome = try PDFShrinker.fit(src, target: 1_000, workDir: fx.dir) { steps.append($0.dpi) }
        XCTAssertEqual(steps, [300, 220, 150])
        guard case .tooBig(let best, let step) = outcome else { return XCTFail("expected .tooBig") }
        XCTAssertEqual(step, PDFShrinker.Step(dpi: 150, quality: 0.75))
        XCTAssertTrue(FileManager.default.fileExists(atPath: best.path))
    }

    func testSplitMakesPartsUnderTheTarget() throws {
        let src = fx.heavyPDF("heavy.pdf", pages: 6, imagePixels: 900)
        let total = PDFTools.size(src)
        let target = total / 2
        let parts = try PDFShrinker.split(src, target: target, folder: fx.dir, base: "Heavy")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertTrue(parts[0].lastPathComponent.hasPrefix("Heavy – Part 1 of \(parts.count)"))
        for part in parts { XCTAssertLessThanOrEqual(PDFTools.size(part), target) }
        let pages = parts.reduce(0) { $0 + (PDFDocument(url: $1)?.pageCount ?? 0) }
        XCTAssertEqual(pages, 6)
    }

    func testOCRAddsInvisibleTextOnlyToScans() throws {
        let scan = fx.scannedPDF("scan.pdf", words: "Mitochondria powerhouse")
        let out = fx.url("searchable.pdf")
        let count = try OCRService.makeSearchable(scan, to: out) { _, _ in }
        XCTAssertEqual(count, 1)
        let page = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0))
        XCTAssertTrue(page.string?.localizedCaseInsensitiveContains("Mitochondria") ?? false, page.string ?? "nil")

        // The page looks the same: the text is invisible.
        let before = try XCTUnwrap(OCRService.render(try XCTUnwrap(PDFDocument(url: scan)?.page(at: 0)?.pageRef)))
        let after = try XCTUnwrap(OCRService.render(try XCTUnwrap(page.pageRef)))
        XCTAssertLessThan(meanDifference(before, after), 1.0)

        // A page that already has text is left alone.
        let text = fx.textPDF("text.pdf", pages: 1, label: "Typed")
        XCTAssertEqual(try OCRService.makeSearchable(text, to: fx.url("text-out.pdf")) { _, _ in }, 0)
    }

    func testOCROnRotatedScanIsUpright() throws {
        let scan = fx.scannedPDF("rotated.pdf", words: "Photosynthesis", sideways: true)
        let out = fx.url("rotated-out.pdf")
        try OCRService.makeSearchable(scan, to: out) { _, _ in }
        let page = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 792, height: 612), "rotation applied")
        XCTAssertTrue(page.string?.localizedCaseInsensitiveContains("Photosynthesis") ?? false, page.string ?? "nil")
    }

    func testOCRTextSurvivesShrinking() throws {
        let scan = fx.scannedPDF("scan.pdf", words: "Ribosome assembly")
        let ocr = fx.url("ocr.pdf")
        try OCRService.makeSearchable(scan, to: ocr) { _, _ in }
        let shrunk = fx.url("shrunk.pdf")
        try PDFShrinker.render(ocr, step: PDFShrinker.ladder[2], to: shrunk)
        XCTAssertTrue(PDFDocument(url: shrunk)?.page(at: 0)?.string?.localizedCaseInsensitiveContains("Ribosome") ?? false)
    }

    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 200, h = 260
        func pixels(_ image: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        return Double(zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(w * h)
    }
}

final class PipelineTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() { fx.cleanUp() }

    private func options(_ folder: URL, name: String, ocr: Bool = false, shrink: Bool = true, target: Int64 = 30_000_000) -> JobOptions {
        JobOptions(ocr: ocr, shrink: shrink, targetBytes: target, stripLocation: true, folder: folder, baseName: name)
    }

    func testMixedMergeNeverTouchesOriginalsOrOverwrites() async throws {
        let pdf = fx.textPDF("Lecture 1.pdf", pages: 2, label: "Lecture one")
        let photo = fx.image("IMG_1.HEIC", type: .heic, orientation: 6)
        let doc = fx.url("Notes.docx")
        try Data("not really a docx".utf8).write(to: doc)
        let inputs = [pdf, photo, doc]
        let digests = try inputs.map(fx.digest)
        let files = inputs.compactMap(InputFile.load)
        XCTAssertEqual(files.count, 3)

        let out = fx.dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: out.appendingPathComponent("Merged.pdf"))
        let work = fx.dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let (prepared, skipped) = try await Pipeline.prepare(files, workDir: work) { _ in }
        XCTAssertEqual(prepared.count, OfficeConverter.isInstalled ? 2 : 2, "the fake docx can't be converted either way")
        XCTAssertNotNil(skipped[files[2].id])

        let pages = files.compactMap { prepared[$0.id] }.flatMap { p in (0..<p.pageCount).map { PageRef(fileID: p.fileID, index: $0) } }
        let result = try Pipeline.merge(pages: pages, sources: prepared, options: options(out, name: "Merged"),
                                        workDir: work, skipped: Array(skipped.values)) { _ in }
        XCTAssertEqual(result.outputs.first?.lastPathComponent, "Merged (2).pdf")
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.title, "Merged 2 files")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Merged.pdf"), encoding: .utf8), "existing")
        XCTAssertEqual(try inputs.map(fx.digest), digests, "originals unchanged")
        let merged = try XCTUnwrap(PDFDocument(url: result.outputs[0]))
        XCTAssertEqual(merged.outlineRoot?.numberOfChildren, 2)
    }

    func testMergeOverLimitKeepsFullQualityAndOffersSplit() async throws {
        let heavy = fx.heavyPDF("heavy.pdf", pages: 2)
        let file = try XCTUnwrap(InputFile.load(heavy))
        let work = fx.dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (prepared, _) = try await Pipeline.prepare([file], workDir: work) { _ in }
        let pages = [PageRef(fileID: file.id, index: 0), PageRef(fileID: file.id, index: 1)]
        let result = try Pipeline.merge(pages: pages, sources: prepared, options: options(fx.dir, name: "Big", target: 1000),
                                        workDir: work, skipped: []) { _ in }
        let over = try XCTUnwrap(result.overLimit)
        XCTAssertEqual(result.bytes, PDFTools.size(heavy), accuracy: Int64(Double(PDFTools.size(heavy)) * 0.05))
        let split = try Pipeline.split(over) { _ in }
        XCTAssertEqual(split.outputs.count, 2, "one page per part when every page is over the limit")
    }

    func testConvertToJPEGPutsSeveralIntoAFolder() throws {
        let files = [fx.image("a.heic", type: .heic), fx.image("b.png", type: .png), fx.image("c.jpg", type: .jpeg)]
            .compactMap(InputFile.load)
        let result = try Pipeline.convertToJPEG(files, options: options(fx.dir, name: "Converted")) { _ in }
        XCTAssertEqual(result.outputs.map(\.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertEqual(result.outputs[0].deletingLastPathComponent().lastPathComponent, "Converted")
        XCTAssertEqual(result.note, "Left out: 1 already JPEG · Location removed")
    }

    func testConvertOneImageUsesTheNameField() throws {
        let files = [fx.image("IMG_9.heic", type: .heic)].compactMap(InputFile.load)
        let result = try Pipeline.convertToJPEG(files, options: options(fx.dir, name: "Receipt")) { _ in }
        XCTAssertEqual(result.outputs.map(\.lastPathComponent), ["Receipt.jpg"])
        XCTAssertEqual(result.outputs[0].deletingLastPathComponent().standardizedFileURL, fx.dir.standardizedFileURL)
    }

    func testConvertToPDFSeparateOrCombined() throws {
        let files = [fx.image("a.heic", type: .heic), fx.image("b.png", type: .png)].compactMap(InputFile.load)
        let separate = try Pipeline.convertToPDF(files, combine: false, options: options(fx.dir, name: "Pics"),
                                                 workDir: fx.dir) { _ in }
        XCTAssertEqual(separate.outputs.map(\.lastPathComponent), ["a.pdf", "b.pdf"])
        let combined = try Pipeline.convertToPDF(files, combine: true, options: options(fx.dir, name: "Pics"),
                                                 workDir: fx.dir) { _ in }
        XCTAssertEqual(combined.outputs.map(\.lastPathComponent), ["Pics.pdf"])
        XCTAssertEqual(combined.pageCount, 2)
    }

    func testOfficeConversionWhenInstalled() async throws {
        try XCTSkipUnless(OfficeConverter.isInstalled, "LibreOffice isn't installed")
        let rtf = fx.url("Essay.rtf")
        try Data(#"{\rtf1\ansi Hello from Word}"#.utf8).write(to: rtf)
        let pdf = try await OfficeConverter.convert(rtf, workDir: fx.dir)
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Hello") ?? false)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fx.dir.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".~lock") }, "no lock files next to the original")
    }
}
