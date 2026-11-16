import PDFKit
import XCTest
@testable import Stitch

/// The fixes from docs/audits/SECURITY-AUDIT.md.
final class SecurityTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() { fx.cleanUp() }

    private func request(_ original: URL, password: String? = nil, overlays: [Overlay] = []) throws -> SaveCopy.Request {
        let work = fx.dir.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return SaveCopy.Request(original: original, password: password, overlays: overlays,
                                fallbackFolder: fx.dir, workDir: work)
    }

    private func signature() throws -> Signature {
        try XCTUnwrap(Signature.drawn(strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 20), CGPoint(x: 80, y: 5)],
                                                [CGPoint(x: 0, y: 20), CGPoint(x: 80, y: 0)]]))
    }

    // M2: a password-protected PDF stays protected.
    func testSavedCopyOfPasswordProtectedPDFKeepsThePassword() throws {
        let src = fx.textPDF("Statement.pdf", pages: 1, label: "Statement")
        let locked = fx.url("Locked.pdf")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: src)).write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "owner"]))
        let overlay = Overlay(page: 0, rect: CGRect(x: 300, y: 100, width: 160, height: 40), rotation: 0, kind: .signature(try signature()))
        let out = try SaveCopy.run(request(locked, password: "pw", overlays: [overlay]))

        XCTAssertThrowsError(try MuPDFDocument(url: out.url)) { XCTAssertEqual($0 as? MuPDFDocument.Failure, .needsPassword) }
        let doc = try XCTUnwrap(PDFDocument(url: out.url))
        XCTAssertTrue(doc.isLocked, "the signed copy still needs the password")
        XCTAssertTrue(doc.unlock(withPassword: "pw"))
        XCTAssertTrue(doc.page(at: 0)?.string?.contains("Statement page 1") ?? false)
        XCTAssertTrue(try MuPDFDocument(url: out.url, password: "pw").isEncrypted)
    }

    func testUnprotectedPDFStaysUnprotected() throws {
        let src = fx.textPDF("Plain.pdf", pages: 1, label: "Plain")
        let out = try SaveCopy.run(request(src))
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: out.url)).isLocked)
        XCTAssertFalse(try MuPDFDocument(url: out.url).isEncrypted)
    }

    // L4: a page that leaves q's, a zero-area clip and a text object open can't hide the stamp.
    func testStampIsVisibleOnAPageWithUnbalancedGraphicsState() throws {
        let hostile = fx.url("Hostile.pdf")
        try rawPDF(content: "q 0 0 0 0 re W n q q BT /F1 24 Tf 60 700 Td (Hostile) Tj").write(to: hostile)
        XCTAssertEqual(try MuPDFDocument(url: hostile).pageCount, 1)
        let rect = CGRect(x: 300, y: 100, width: 160, height: 40)
        let overlay = Overlay(page: 0, rect: rect, rotation: 0, kind: .signature(try signature()))
        let out = try SaveCopy.run(request(hostile, overlays: [overlay]))
        XCTAssertGreaterThan(darkPixels(out.url, in: rect), 50, "the signature is drawn, not clipped away")
    }

    // L5: a white cover box removes what's under it from the saved file.
    func testWhiteCoverBoxRemovesTheTextUnderIt() throws {
        let src = fx.textPDF("Form.pdf", pages: 1, label: "SECRET123")
        var box = TextBox(text: "")
        box.whiteBackground = true
        let cover = Overlay(page: 0, rect: CGRect(x: 40, y: 670, width: 500, height: 60), rotation: 0, kind: .text(box))
        let out = try SaveCopy.run(request(src, overlays: [cover]))
        let text = try XCTUnwrap(PDFDocument(url: out.url)?.page(at: 0)?.string ?? "")
        XCTAssertFalse(text.contains("SECRET123"), "covered text is gone, not just hidden: \(text)")
    }

    func testPlainTextBoxLeavesTheTextUnderIt() throws {
        let src = fx.textPDF("Form.pdf", pages: 1, label: "Visible")
        let note = Overlay(page: 0, rect: CGRect(x: 40, y: 600, width: 200, height: 30), rotation: 0, kind: .text(TextBox(text: "Note")))
        let out = try SaveCopy.run(request(src, overlays: [note]))
        XCTAssertTrue(PDFDocument(url: out.url)?.page(at: 0)?.string?.contains("Visible page 1") ?? false)
    }

    // I3: a later save never replaces a different file put where the last copy was.
    func testLaterSaveLeavesAFileThatReplacedItsCopyAlone() throws {
        let src = fx.textPDF("Lease.pdf", pages: 1, label: "Lease")
        let first = try SaveCopy.run(request(src))
        XCTAssertNotNil(first.fileID)
        try FileManager.default.removeItem(at: first.url)
        try Data("someone else's file".utf8).write(to: first.url)
        var again = try request(src)
        again.previousCopy = first.url
        again.previousCopyID = first.fileID
        let second = try SaveCopy.run(again)
        XCTAssertNotEqual(second.url, first.url)
        XCTAssertEqual(try String(contentsOf: first.url, encoding: .utf8), "someone else's file")

        var third = try request(src)
        third.previousCopy = second.url
        third.previousCopyID = second.fileID
        XCTAssertEqual(try SaveCopy.run(third).url, second.url, "its own copy is still updated in place")
    }

    // Bug scan H7: an original opened through a symlink is still the original.
    func testNeverSavesOverAnOriginalOpenedThroughASymlink() throws {
        let real = fx.textPDF("Real.pdf", pages: 1, label: "Real")
        let link = fx.url("Link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let before = try fx.digest(real)
        var r = try request(link)
        r.exactDestination = real
        XCTAssertThrowsError(try SaveCopy.run(r)) { XCTAssertEqual(($0 as? SaveCopy.Failure)?.errorDescription, SaveCopy.Failure.wouldReplaceOriginal.errorDescription) }
        var other = try request(real)
        other.exactDestination = link
        XCTAssertThrowsError(try SaveCopy.run(other), "the link to the original counts too")
        XCTAssertEqual(try fx.digest(real), before)
    }

    // L2
    func testDocumentLinksOnlyOpenWebAndMailAfterAsking() {
        XCTAssertEqual(DocumentLink.decision(for: URL(string: "https://example.com")!), .ask)
        XCTAssertEqual(DocumentLink.decision(for: URL(string: "HTTP://example.com")!), .ask)
        XCTAssertEqual(DocumentLink.decision(for: URL(string: "mailto:a@b.c")!), .ask)
        XCTAssertEqual(DocumentLink.decision(for: URL(fileURLWithPath: "/Applications/Calculator.app")), .refuse)
        XCTAssertEqual(DocumentLink.decision(for: URL(string: "x-apple.systempreferences:com.apple.preference")!), .refuse)
        XCTAssertEqual(DocumentLink.decision(for: URL(string: "javascript:alert(1)")!), .refuse)
    }

    // L1
    func testLibreOfficeProfileLocksMacrosAndLinks() {
        let fresh = OfficeConverter.lockedRegistry("")
        XCTAssertTrue(fresh.hasPrefix("<?xml"))
        XCTAssertTrue(fresh.contains(#"oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value>"#))
        XCTAssertTrue(fresh.contains(#"oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value>"#))
        XCTAssertTrue(fresh.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("</oor:items>"))

        let existing = """
            <?xml version="1.0" encoding="UTF-8"?>
            <oor:items xmlns:oor="http://openoffice.org/2001/registry">
            <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="UseOpenCL" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>0</value></prop></item>
            </oor:items>
            """
        let merged = OfficeConverter.lockedRegistry(existing)
        XCTAssertTrue(merged.contains("UseOpenCL"), "other settings are kept")
        XCTAssertFalse(merged.contains("<value>0</value>"), "a weaker macro level is replaced")
        XCTAssertEqual(merged.components(separatedBy: "MacroSecurityLevel").count, 2)
        XCTAssertEqual(OfficeConverter.lockedRegistry(merged), merged, "merging again changes nothing")
    }

    // I5
    func testHugeCSVIsRefusedInsteadOfPadded() throws {
        let src = fx.url("wide.csv")
        let wide = String(repeating: ",", count: 3000) + "x\n"
        try (wide + String(repeating: "a\n", count: 1000)).write(to: src, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CSVConverter.writePDF(from: src, to: fx.url("wide.pdf"))) {
            guard case CSVConverter.Failure.tooLarge = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: helpers

    /// A one-page PDF with exactly this content stream (Helvetica as /F1), with a correct xref table.
    private func rawPDF(content: String) -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { pdf += String(format: "%010d 00000 n \n", o) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    /// Dark pixels inside `rect` (PDF points, page 1) when the PDF is drawn at 1 pixel per point.
    private func darkPixels(_ url: URL, in rect: CGRect) -> Int {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return 0 }
        let box = page.getBoxRect(.mediaBox)
        let w = Int(box.width), h = Int(box.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return 0 }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.drawPDFPage(page)
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        var dark = 0
        for y in Int(rect.minY)..<min(Int(rect.maxY), h) {
            let row = h - 1 - y   // bitmap rows run top to bottom
            for x in Int(rect.minX)..<min(Int(rect.maxX), w) where pixels[row * w + x] < 128 { dark += 1 }
        }
        return dark
    }
}
