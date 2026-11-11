import PDFKit
import XCTest
@testable import Stitch

final class MuPDFTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() { fx.cleanUp() }

    func testOpenSaveRoundTripKeepsEveryPage() throws {
        let src = fx.textPDF("Five.pdf", pages: 5, label: "Round")
        let doc = try MuPDFDocument(url: src)
        XCTAssertEqual(doc.pageCount, 5)
        let out = fx.url("out.pdf")
        try doc.save(to: out)
        let saved = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(saved.pageCount, 5)
        XCTAssertEqual(saved.page(at: 4)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Round page 5")
    }

    func testStructuredTextFindsWordsWithSizeAndPosition() throws {
        let doc = try MuPDFDocument(url: fx.textAndImagePDF("Text.pdf"))
        let blocks = TextLayout.blocks(from: try doc.chars(onPage: 0), page: 0)
        let alpha = try XCTUnwrap(blocks.first { $0.text.contains("Alpha page 1") })
        XCTAssertEqual(alpha.fontSize, 24, accuracy: 0.5)
        // Drawn at y = 700 (from the bottom) on a 792 pt page: the baseline is 92 pt from the top.
        XCTAssertEqual(alpha.lines[0].baseline, 92, accuracy: 1)
        XCTAssertEqual(alpha.rect.minX, 72, accuracy: 2)
        XCTAssertTrue(alpha.fontName.hasPrefix("Helvetica"))
    }

    func testRemovingTextKeepsOtherWordsAndTheImage() throws {
        let src = fx.textAndImagePDF("Text.pdf")
        let doc = try MuPDFDocument(url: src)
        let blocks = TextLayout.blocks(from: try doc.chars(onPage: 0), page: 0)
        let fox = try XCTUnwrap(blocks.first { $0.text.contains("quick brown fox") })
        try doc.removeText(onPage: 0, in: fox.removalRects)
        let out = fx.url("out.pdf")
        try doc.save(to: out)
        let text = PDFDocument(url: out)?.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.contains("quick"))
        XCTAssertTrue(text.contains("Alpha page 1"))
        XCTAssertTrue(text.contains("Keep this line"))
        XCTAssertEqual(imageCount(out), 1, "the image is untouched")
    }

    func testPlacingAStampMakesItsTextReadableInPlace() throws {
        let src = fx.textPDF("Base.pdf", pages: 1, label: "Base")
        let stamp = fx.url("stamp.pdf")
        try StampRenderer.write(size: CGSize(width: 200, height: 30), to: stamp) { ctx in
            fx.draw("Stamped words", in: ctx, at: CGPoint(x: 2, y: 8), size: 14)
        }
        let doc = try MuPDFDocument(url: src)
        try doc.place(stamp, onPage: 0, transform: CGAffineTransform(translationX: 300, y: 100))
        let out = fx.url("out.pdf")
        try doc.save(to: out)
        let saved = try XCTUnwrap(PDFDocument(url: out))
        let page = try XCTUnwrap(saved.page(at: 0))
        XCTAssertTrue(page.string?.contains("Stamped words") ?? false)
        let selection = try XCTUnwrap(saved.findString("Stamped words", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        XCTAssertEqual(bounds.minX, 302, accuracy: 3)
        XCTAssertEqual(bounds.minY, 105, accuracy: 6)
    }

    func testEditingOneLineChangesOnlyThatLine() throws {
        let src = fx.textAndImagePDF("Text.pdf")
        let doc = try MuPDFDocument(url: src)
        let blocks = TextLayout.blocks(from: try doc.chars(onPage: 0), page: 0)
        let fox = try XCTUnwrap(blocks.first { $0.text.contains("quick brown fox") })
        let edit = TextEdit(block: fox, text: fox.text.replacingOccurrences(of: "brown", with: "red"))
        try StampRenderer.apply([edit], to: doc, workDir: fx.dir)
        let out = fx.url("out.pdf")
        try doc.save(to: out)
        let text = PDFDocument(url: out)?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("The quick red fox"), text)
        XCTAssertFalse(text.contains("brown"))
        XCTAssertTrue(text.contains("Alpha page 1"))
        XCTAssertTrue(text.contains("Keep this line"))
        XCTAssertEqual(imageCount(out), 1)

        // The new text sits on the old baseline.
        let reread = try MuPDFDocument(url: out)
        let red = try XCTUnwrap(TextLayout.blocks(from: try reread.chars(onPage: 0), page: 0).first { $0.text.contains("red fox") })
        XCTAssertEqual(red.lines[0].baseline, fox.lines[0].baseline, accuracy: 0.6)
        XCTAssertEqual(red.rect.minX, fox.rect.minX, accuracy: 1)
    }

    func testLongerReplacementShrinksThenGrowsButStaysOnThePage() throws {
        let doc = try MuPDFDocument(url: fx.textAndImagePDF("Text.pdf"))
        let fox = try XCTUnwrap(TextLayout.blocks(from: try doc.chars(onPage: 0), page: 0).first { $0.text.contains("fox") })
        let long = TextEdit(block: fox, text: "The quick brown fox jumps over the lazy dog and keeps running far beyond the edge of the line")
        let laid = TextLayout.layout(long)
        XCTAssertGreaterThan(laid.lines.count, 1, "wraps at the block width")
        XCTAssertTrue(laid.shrunk)
        XCTAssertGreaterThanOrEqual(laid.fontSize, fox.fontSize * 0.8 - 0.01)
        XCTAssertLessThanOrEqual(laid.rect.maxX, 612)
        try StampRenderer.apply([long], to: doc, workDir: fx.dir)
        let out = fx.url("out.pdf")
        try doc.save(to: out)
        let text = PDFDocument(url: out)?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("lazy dog"))
    }

    func testFormFieldsListAndFill() throws {
        let src = fx.formPDF("Form.pdf")
        let doc = try MuPDFDocument(url: src)
        let fields = try doc.fields()
        XCTAssertEqual(Set(fields.map(\.name)), ["First Name", "Email", "Student ID", "Agree"])
        try doc.setField("First Name", to: "Liam")
        try doc.setField("Agree", to: "On")
        XCTAssertThrowsError(try doc.setField("Nope", to: "x"))
        let out = fx.url("filled.pdf")
        try doc.save(to: out)
        let refilled = try MuPDFDocument(url: out).fields()
        XCTAssertEqual(refilled.first { $0.name == "First Name" }?.value, "Liam")
        XCTAssertNotEqual(refilled.first { $0.name == "Agree" }?.value, "Off")
        let page = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0))
        XCTAssertEqual(page.annotations.first { $0.fieldName == "First Name" }?.widgetStringValue, "Liam")
    }

    func testPasswordProtectedNeedsThePassword() throws {
        let src = fx.textPDF("Secret.pdf", pages: 1, label: "Secret")
        let locked = fx.url("Locked.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: src))
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "owner"]))
        XCTAssertThrowsError(try MuPDFDocument(url: locked)) { XCTAssertEqual($0 as? MuPDFDocument.Failure, .needsPassword) }
        XCTAssertThrowsError(try MuPDFDocument(url: locked, password: "bad")) { XCTAssertEqual($0 as? MuPDFDocument.Failure, .wrongPassword) }
        XCTAssertEqual(try MuPDFDocument(url: locked, password: "pw").pageCount, 1)
    }

    private func imageCount(_ url: URL) -> Int {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1), let dict = page.dictionary else { return 0 }
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res else { return 0 }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xobjects else { return 0 }
        var count = 0
        CGPDFDictionaryApplyBlock(xobjects, { _, obj, info in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(obj, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) {
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(d, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                    info!.assumingMemoryBound(to: Int.self).pointee += 1
                }
            }
            return true
        }, &count)
        return count
    }
}

final class SaveCopyTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() {
        let readOnly = fx.dir.appendingPathComponent("ro")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
        fx.cleanUp()
    }

    private func request(_ original: URL, overlays: [Overlay] = []) throws -> SaveCopy.Request {
        let work = fx.dir.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fallback = fx.dir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return SaveCopy.Request(original: original, overlays: overlays, fallbackFolder: fallback, workDir: work)
    }

    func testUnchangedPDFSavesAsEditedNextToItAndNeverTouchesTheOriginal() throws {
        let original = fx.textPDF("Lease.pdf", pages: 2, label: "Lease")
        let before = try fx.digest(original)
        let first = try SaveCopy.run(request(original))
        XCTAssertEqual(first.url.lastPathComponent, "Lease_edited.pdf")
        XCTAssertEqual(first.url.deletingLastPathComponent().standardizedFileURL, fx.dir.standardizedFileURL)
        XCTAssertFalse(first.usedFallback)
        let second = try SaveCopy.run(request(original))
        XCTAssertEqual(second.url.lastPathComponent, "Lease_edited (2).pdf", "adds (2) instead of overwriting")
        XCTAssertEqual(try fx.digest(original), before, "original unchanged")
        XCTAssertEqual(PDFDocument(url: first.url)?.pageCount, 2)
    }

    func testSignedCopyIsNamedSignedAndSignatureStaysVector() throws {
        let original = fx.textPDF("Lease.pdf", pages: 1, label: "Lease")
        let sig = try XCTUnwrap(Signature.drawn(strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 20), CGPoint(x: 80, y: 5)]]))
        let overlay = Overlay(page: 0, rect: CGRect(x: 300, y: 100, width: 160, height: 40), rotation: 0, kind: .signature(sig))
        let out = try SaveCopy.run(request(original, overlays: [overlay]))
        XCTAssertEqual(out.url.lastPathComponent, "Lease_signed.pdf")
        let data = try String(contentsOf: out.url, encoding: .isoLatin1)
        XCTAssertFalse(data.contains("/Subtype /Image") || data.contains("/Subtype/Image"), "no image was added for the signature")
        XCTAssertTrue(data.contains("StitchStamp1"))
    }

    func testUpdatesItsOwnPreviousCopy() throws {
        let original = fx.textPDF("Form.pdf", pages: 1, label: "Form")
        let first = try SaveCopy.run(request(original))
        var again = try request(original)
        again.previousCopy = first.url
        let box = Overlay(page: 0, rect: CGRect(x: 72, y: 72, width: 100, height: 20), rotation: 0, kind: .text(TextBox(text: "Hello there")))
        again.overlays = [box]
        let second = try SaveCopy.run(again)
        XCTAssertEqual(second.url, first.url)
        XCTAssertTrue(PDFDocument(url: second.url)?.page(at: 0)?.string?.contains("Hello there") ?? false)
    }

    func testNeverSavesOverTheOriginal() throws {
        let original = fx.textPDF("Mine.pdf", pages: 1, label: "Mine")
        let before = try fx.digest(original)
        var r = try request(original)
        r.exactDestination = original
        XCTAssertThrowsError(try SaveCopy.run(r))
        r.exactDestination = nil
        r.previousCopy = original
        let out = try SaveCopy.run(r)
        XCTAssertNotEqual(out.url.standardizedFileURL, original.standardizedFileURL)
        XCTAssertEqual(try fx.digest(original), before)
    }

    func testNeverWritesTheOriginalUnderAnotherCaseOrAnotherTabsOriginal() throws {
        let original = fx.textPDF("Lease.pdf", pages: 1, label: "Lease")
        let other = fx.textPDF("Other.pdf", pages: 1, label: "Other")
        let before = try [original, other].map(fx.digest)
        var r = try request(original)
        r.exactDestination = fx.url("lease.PDF")
        XCTAssertThrowsError(try SaveCopy.run(r), "same file on a case-insensitive disk")
        r.exactDestination = other
        r.protected = [other]
        XCTAssertThrowsError(try SaveCopy.run(r), "another tab's original")
        r.exactDestination = nil
        r.previousCopy = other
        let out = try SaveCopy.run(r)
        XCTAssertEqual(out.url.lastPathComponent, "Lease_edited.pdf")
        XCTAssertEqual(try [original, other].map(fx.digest), before)
    }

    func testReadOnlyFolderFallsBackToDownloads() throws {
        let folder = fx.dir.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Attachment.pdf")
        try FileManager.default.copyItem(at: fx.textPDF("a.pdf", pages: 1, label: "A"), to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let r = try request(original)
        let out = try SaveCopy.run(r)
        XCTAssertTrue(out.usedFallback)
        XCTAssertEqual(out.url.deletingLastPathComponent().standardizedFileURL, r.fallbackFolder.standardizedFileURL)
        XCTAssertEqual(out.url.lastPathComponent, "Attachment_edited.pdf")
    }

    func testFormValuesSurviveSaveCopy() throws {
        let original = fx.formPDF("Application.pdf")
        var r = try request(original)
        r.formValues = ["First Name": "Liam", "Student ID": "1234567890", "Agree": "Yes"]
        let out = try SaveCopy.run(r)
        let fields = try MuPDFDocument(url: out.url).fields()
        XCTAssertEqual(fields.first { $0.name == "First Name" }?.value, "Liam")
        XCTAssertEqual(fields.first { $0.name == "Student ID" }?.value, "1234567890")
        XCTAssertNotEqual(fields.first { $0.name == "Agree" }?.value, "Off")
    }

    func testRotatedPageOverlayLandsUpright() throws {
        let src = fx.textPDF("Turned.pdf", pages: 1, label: "Turned")
        let doc = try XCTUnwrap(PDFDocument(url: src))
        doc.page(at: 0)?.rotation = 90
        let original = fx.url("Rotated.pdf")
        XCTAssertTrue(doc.write(to: original))
        let size = CGSize(width: 120, height: 20)   // upright
        let rect = CGRect(origin: CGPoint(x: 200, y: 200), size: PageGeometry.userSize(ofUpright: size, rotation: 90))
        let box = Overlay(page: 0, rect: rect, rotation: 90, kind: .text(TextBox(text: "Upright note")))
        let out = try SaveCopy.run(request(original, overlays: [box]))
        let reread = try MuPDFDocument(url: out.url)
        let block = try XCTUnwrap(TextLayout.blocks(from: try reread.chars(onPage: 0), page: 0).first { $0.text.contains("Upright note") })
        XCTAssertGreaterThan(block.rect.width, block.rect.height * 3, "reads left to right as shown")
    }
}

final class AutoFillTests: XCTestCase {
    func testRealWorldFieldNames() {
        let cases: [(String, ProfileItem?)] = [
            ("First Name", .firstName), ("fname", .firstName), ("fName", .firstName), ("Given Name", .firstName),
            ("Last Name", .lastName), ("Surname", .lastName), ("lname", .lastName),
            ("Name", .fullName), ("Full Name", .fullName), ("Applicant Name", .fullName), ("Print Name", .fullName),
            ("Email", .email), ("E-mail", .email), ("Applicant Email", .email), ("email_address", .email),
            ("Phone #", .phone), ("Telephone", .phone), ("Mobile", .phone), ("Cell Phone", .phone),
            ("DOB", .dateOfBirth), ("Date of Birth", .dateOfBirth), ("Birthdate", .dateOfBirth),
            ("Student ID", .studentID), ("USC ID", .studentID), ("Student Number", .studentID),
            ("Street Address", .street), ("Address", .street), ("Address Line 1", .street), ("Mailing Address", .street),
            ("Address Line 2", .street2), ("Apt", .street2),
            ("City", .city), ("State", .state), ("Zip", .zip), ("Zip Code", .zip), ("Postal Code", .zip), ("Country", .country),
            ("topmostSubform[0].Page1[0].FirstName[0]", .firstName),
            ("Emergency Contact Name", nil), ("Emergency Contact Phone", nil), ("Parent Email", nil),
            ("Employer Address", nil), ("School Name", nil), ("Middle Name", nil), ("Date", nil),
            ("Signature", nil), ("Text1", nil), ("Statement", nil),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(AutoFill.match(name), expected, name)
        }
    }

    func testProfileValues() {
        var p = Profile(firstName: "Liam", lastName: "Blackshaw-Brown")
        p.addresses = [Profile.Address(label: "School", street: "1 Trojan Way", city: "Los Angeles", state: "CA", zip: "90007")]
        XCTAssertEqual(p.value(.fullName), "Liam Blackshaw-Brown")
        XCTAssertEqual(p.value(.fullAddress), "1 Trojan Way, Los Angeles, CA 90007")
        XCTAssertEqual(p.value(.zip), "90007")
    }
}

final class SigningTests: XCTestCase {
    func testDrawnSignatureNormalizesAndRoundTrips() throws {
        let sig = try XCTUnwrap(Signature.drawn(strokes: [[CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 150)], [CGPoint(x: 120, y: 60)]]))
        XCTAssertEqual(sig.aspect, 2, accuracy: 0.2)
        for p in sig.strokes.flatMap({ $0 }) {
            XCTAssertTrue((0...sig.aspect).contains(p.x) && (0...1).contains(p.y))
        }
        let data = try JSONEncoder().encode(sig)
        XCTAssertEqual(try JSONDecoder().decode(Signature.self, from: data), sig)
    }

    func testTypedSignatureHasAShape() throws {
        let sig = try XCTUnwrap(Signature.typed("Liam Blackshaw-Brown", fontName: "SnellRoundhand"))
        XCTAssertGreaterThan(sig.aspect, 3)
        XCTAssertNil(Signature.typed("   ", fontName: "SnellRoundhand"))
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "com.liamblackshawbrown.Stitch.tests")
        defer { store.delete(account: "probe") }
        let sig = try XCTUnwrap(Signature.typed("LBB", fontName: "SnellRoundhand"))
        try store.save(sig, account: "probe")
        XCTAssertEqual(store.load(Signature.self, account: "probe"), sig)
        try store.save(Profile(firstName: "A"), account: "probe")
        XCTAssertEqual(store.load(Profile.self, account: "probe")?.firstName, "A")
    }

    func testFontMatcher() {
        XCTAssertEqual(FontMatcher.stripSubset("ABCDEF+Helvetica-Bold"), "Helvetica-Bold")
        XCTAssertEqual(FontMatcher.stripSubset("Helvetica"), "Helvetica")
        XCTAssertEqual(FontMatcher.match(pdfFontName: "ABCDEF+Helvetica", bold: false, italic: false, serif: false, mono: false),
                       .init(postScriptName: "Helvetica", exact: true))
        let times = FontMatcher.match(pdfFontName: "XYZABC+SomeSerifBook", bold: false, italic: false, serif: true, mono: false)
        XCTAssertTrue(times.postScriptName.hasPrefix("Times"), times.postScriptName)
        let bold = FontMatcher.match(pdfFontName: "QWERTY+Calibri-Bold", bold: true, italic: false, serif: false, mono: false)
        XCTAssertTrue(bold.postScriptName.contains("Bold"), bold.postScriptName)
    }

    func testUprightTransformMapsCorners() {
        let rect = CGRect(x: 100, y: 200, width: 20, height: 60)
        let t = PageGeometry.uprightTransform(for: rect, rotation: 90)
        let size = PageGeometry.uprightSize(of: rect, rotation: 90)
        XCTAssertEqual(size, CGSize(width: 60, height: 20))
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { $0.applying(t) }
        let bounds = corners.dropFirst().reduce(CGRect(origin: corners[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        XCTAssertEqual(bounds.integral, rect)
    }
}

@MainActor
final class EditSessionTests: XCTestCase {
    var fx: Fixtures!

    override func setUpWithError() throws { fx = try Fixtures() }
    override func tearDown() { fx.cleanUp() }

    func testOverlaysUndoAndRedo() throws {
        let session = try EditSession(original: fx.textPDF("Lease.pdf", pages: 1, label: "Lease"), password: nil)
        defer { session.close() }
        // In the app each action is its own event; here, group them by hand.
        let undo = session.undoManager
        undo.groupsByEvent = false
        func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
        let ov = Overlay(page: 0, rect: CGRect(x: 10, y: 10, width: 50, height: 20), rotation: 0, kind: .text(TextBox(text: "Hi")))
        step { session.add(ov, actionName: "Text Box") }
        var moved = ov
        moved.rect.origin.x = 100
        step { session.update(moved, actionName: "Move") }
        XCTAssertEqual(session.overlays.first?.rect.minX, 100)
        session.undoManager.undo()
        XCTAssertEqual(session.overlays.first?.rect.minX, 10)
        session.undoManager.undo()
        XCTAssertTrue(session.overlays.isEmpty)
        session.undoManager.redo()
        XCTAssertEqual(session.overlays.count, 1)
        step { session.remove(ov.id) }
        XCTAssertTrue(session.overlays.isEmpty)
        session.undoManager.undo()
        XCTAssertEqual(session.overlays.count, 1)
        XCTAssertTrue(session.hasUnsavedChanges(currentForm: [:]))
    }

    func testTextEditRebuildsWorkingCopyAndUndoRestoresIt() async throws {
        let original = fx.textAndImagePDF("Notice.pdf")
        let before = try fx.digest(original)
        let session = try EditSession(original: original, password: nil)
        defer { session.close() }
        let block = try XCTUnwrap(session.blocks(onPage: 0).first { $0.text.contains("quick brown fox") })
        let info = try XCTUnwrap(session.pageInfo(0))
        let point = CGPoint(x: block.rect.midX, y: block.rect.midY)
        XCTAssertEqual(session.editTarget(at: point, page: 0)?.block, block)
        _ = info

        session.undoManager.groupsByEvent = false
        try await rebuilt(session) {
            session.undoManager.beginUndoGrouping()
            session.commitText("The quick grey fox", for: block, editing: nil)
            session.undoManager.endUndoGrouping()
        }
        XCTAssertTrue(PDFDocument(url: session.workingCopy)?.page(at: 0)?.string?.contains("quick grey fox") ?? false)
        // Clicking the edited text edits that same edit.
        let again = try XCTUnwrap(session.editTarget(at: point, page: 0))
        XCTAssertEqual(again.edit?.text, "The quick grey fox")

        try await rebuilt(session) { session.undoManager.undo() }
        XCTAssertTrue(session.textEdits.isEmpty)
        XCTAssertTrue(PDFDocument(url: session.workingCopy)?.page(at: 0)?.string?.contains("quick brown fox") ?? false)

        try await rebuilt(session) { session.undoManager.redo() }
        let out = try SaveCopy.run(session.saveRequest(fallbackFolder: fx.dir))
        XCTAssertEqual(out.url.lastPathComponent, "Notice_edited.pdf")
        XCTAssertTrue(PDFDocument(url: out.url)?.page(at: 0)?.string?.contains("quick grey fox") ?? false)
        session.didSave(to: out.url)
        XCTAssertFalse(session.hasUnsavedChanges(currentForm: [:]))
        XCTAssertEqual(try fx.digest(original), before)
    }

    func testFormBridgeReadsAndWritesWidgets() throws {
        let doc = try XCTUnwrap(PDFDocument(url: fx.formPDF("Form.pdf")))
        let baseline = FormBridge.values(in: doc)
        XCTAssertEqual(baseline["Agree"], "Off")
        FormBridge.apply(["First Name": "Liam", "Agree": "Yes"], to: try XCTUnwrap(doc.page(at: 0)))
        let changes = FormBridge.changes(FormBridge.values(in: doc), from: baseline)
        XCTAssertEqual(changes["First Name"], "Liam")
        XCTAssertNotNil(changes["Agree"])
        XCTAssertNotEqual(changes["Agree"], "Off")
    }

    private func rebuilt(_ session: EditSession, _ change: () -> Void) async throws {
        let done = expectation(description: "working copy rebuilt")
        session.onWorkingCopyChanged = { _, _ in done.fulfill() }
        change()
        await fulfillment(of: [done], timeout: 20)
        session.onWorkingCopyChanged = nil
    }
}
