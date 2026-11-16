import CoreGraphics
import PDFKit
import XCTest
@testable import Stitch

/// The document window's sidebar: what's on the To-Do list, what Fill My Info will do, History's steps,
/// and Find's replacing.
final class SidebarTests: XCTestCase {
    // MARK: TodoFinder

    private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    private func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 10) -> TodoFinder.Line {
        TodoFinder.Line(text: text, rect: CGRect(x: x, y: y, width: CGFloat(text.count) * size * 0.5, height: size))
    }

    func testLeaseFindsSignatureAndDateSpots() {
        let page = TodoFinder.Page(index: 0, bounds: letter, lines: [
            line("This agreement is made between the Landlord and the Tenant.", x: 72, y: 640, size: 12),
            line("Tenant signature ____________", x: 72, y: 150),
            line("Date ____________", x: 340, y: 150),
        ], widgets: [])
        let items = TodoFinder.find(pages: [page], marks: [])
        XCTAssertEqual(items.map(\.kind), [.signature, .date])
        XCTAssertEqual(items.first?.label, "Tenant signature")
        XCTAssertFalse(items.contains(where: \.done))
        // The spot is the underscores, not the label.
        XCTAssertGreaterThan(items[0].rect.minX, 72 + 60)
    }

    func testLabelUnderADrawnLineFindsTheBlankAboveIt() {
        let page = TodoFinder.Page(index: 0, bounds: letter, lines: [
            line("Rent is due on the first of each month.", x: 72, y: 600, size: 12),
            line("Tenant signature", x: 72, y: 136, size: 9),
            line("Date", x: 340, y: 136, size: 9),
        ], widgets: [])
        let items = TodoFinder.find(pages: [page], marks: [])
        XCTAssertEqual(items.map(\.kind), [.signature, .date])
        XCTAssertGreaterThan(items[0].rect.minY, 136)
    }

    func testDateOfBirthIsNotADateSpotAndBodyTextIsNotASignature() {
        let page = TodoFinder.Page(index: 0, bounds: letter, lines: [
            line("Date of birth ________", x: 72, y: 500),
            line("The signature of the Tenant below confirms they have read every page of this lease.", x: 72, y: 400),
        ], widgets: [])
        XCTAssertTrue(TodoFinder.find(pages: [page], marks: []).isEmpty)
    }

    func testInitialsFooterOnEveryPage() {
        let pages = (0..<3).map { i in
            TodoFinder.Page(index: i, bounds: letter, lines: [line("Initials ________", x: 460, y: 50)], widgets: [])
        }
        let items = TodoFinder.find(pages: pages, marks: [])
        XCTAssertEqual(items.map(\.kind), [.initials, .initials, .initials])
        XCTAssertEqual(items.map(\.page), [0, 1, 2])
    }

    func testAPlacedSignatureMarksItsSpotDone() {
        let page = TodoFinder.Page(index: 0, bounds: letter, lines: [line("Tenant signature ____________", x: 72, y: 150)],
                                   widgets: [])
        let spot = TodoFinder.find(pages: [page], marks: [])[0].rect
        let near = TodoFinder.Mark(kind: .signature, page: 0, rect: spot.offsetBy(dx: 0, dy: 8))
        XCTAssertTrue(TodoFinder.find(pages: [page], marks: [near])[0].done)
        let otherPage = TodoFinder.Mark(kind: .signature, page: 1, rect: spot)
        XCTAssertFalse(TodoFinder.find(pages: [page], marks: [otherPage])[0].done)
        let wrongKind = TodoFinder.Mark(kind: .initials, page: 0, rect: spot)
        XCTAssertFalse(TodoFinder.find(pages: [page], marks: [wrongKind])[0].done)
    }

    func testFilledFieldIsDoneEmptyOneIsNot() {
        let widgets = [
            TodoFinder.Widget(name: "Email", label: "Email", rect: CGRect(x: 72, y: 500, width: 200, height: 20), kind: .text, value: "a@b.c"),
            TodoFinder.Widget(name: "Phone", label: "Phone", rect: CGRect(x: 72, y: 460, width: 200, height: 20), kind: .text, value: ""),
            TodoFinder.Widget(name: "Agree", label: "Agree", rect: CGRect(x: 72, y: 420, width: 20, height: 20), kind: .other, value: "Off"),
        ]
        let items = TodoFinder.find(pages: [TodoFinder.Page(index: 0, bounds: letter, lines: [], widgets: widgets)], marks: [])
        XCTAssertEqual(items.map(\.label), ["Email", "Phone"])
        XCTAssertEqual(items.map(\.done), [true, false])
    }

    func testScannedPageYieldsOnlyItsWidgets() {
        let sig = TodoFinder.Widget(name: "Sig1", label: "", rect: CGRect(x: 72, y: 100, width: 200, height: 30), kind: .signature, value: "")
        let items = TodoFinder.find(pages: [TodoFinder.Page(index: 0, bounds: letter, lines: [], widgets: [sig])], marks: [])
        XCTAssertEqual(items.map(\.kind), [.signature])
        XCTAssertEqual(items.first?.fieldName, "Sig1")
    }

    func testLabelBesideASignatureFieldIsNotCountedTwice() {
        let sig = TodoFinder.Widget(name: "Sig", label: "Signature", rect: CGRect(x: 140, y: 146, width: 200, height: 30),
                                    kind: .signature, value: "")
        let page = TodoFinder.Page(index: 0, bounds: letter, lines: [line("Signature:", x: 72, y: 150)], widgets: [sig])
        XCTAssertEqual(TodoFinder.find(pages: [page], marks: []).count, 1)
    }

    // MARK: AutoFill.plan

    func testPlanMatchesFillableFieldsAndSkipsSomeoneElses() {
        var profile = Profile()
        profile.email = "alex@example.com"
        profile.phone = "555-0100"
        let fields = [
            AutoFill.Field(name: "Phone", toolTip: nil, value: "", page: 0, rect: .zero),
            AutoFill.Field(name: "Email", toolTip: nil, value: "old@example.com", page: 0, rect: .zero),
            AutoFill.Field(name: "Emergency Contact Phone", toolTip: nil, value: "", page: 0, rect: .zero),
        ]
        let plan = AutoFill.plan(fields: fields, profile: profile, address: nil)
        XCTAssertEqual(plan.map(\.field.name), ["Phone", "Email"])
        XCTAssertEqual(plan.map(\.alreadyFilled), [false, true])
        XCTAssertEqual(plan.first?.value, "555-0100")
    }

    func testPlanLeavesOutDetailsYouHaventSaved() {
        let fields = [AutoFill.Field(name: "Student ID", toolTip: nil, value: "", page: 0, rect: .zero)]
        XCTAssertTrue(AutoFill.plan(fields: fields, profile: Profile(), address: nil).isEmpty)
    }

    // MARK: HistoryLog

    func testHistoryFollowsUndoRedoAndTruncates() {
        var log = HistoryLog()
        log.record("Signature", summary: "Signed", kind: .signature)
        log.record("Text Box", summary: "Added “A”", kind: .text)
        log.record("Date", summary: "Added the date", kind: .text)
        XCTAssertEqual(log.cursor, 3)
        log.undo()
        log.undo()
        XCTAssertEqual(log.cursor, 1)
        log.redo()
        XCTAssertEqual(log.cursor, 2)
        log.record("Delete", summary: "Deleted", kind: .delete)
        XCTAssertEqual(log.entries.map(\.summary), ["Signed", "Added “A”", "Deleted"])
        XCTAssertEqual(log.cursor, 3)
        XCTAssertFalse(log.canRedo)
    }

    func testOneUndoGroupUndoesTogether() {
        var log = HistoryLog()
        log.record("A", summary: "a", kind: .text, group: 1)
        log.record("B", summary: "b", kind: .text, group: 2)
        log.record("C", summary: "c", kind: .text, group: 2)
        log.undo()
        XCTAssertEqual(log.cursor, 1)
        log.redo()
        XCTAssertEqual(log.cursor, 3)
    }

    func testSamePageTextEditsGroupIntoOneRow() {
        var log = HistoryLog()
        log.record("Signature", summary: "Signed", kind: .signature, page: 0)
        for _ in 0..<3 { log.record("Edit Text", summary: "Changed", kind: .textEdit, page: 1) }
        log.record("Edit Text", summary: "Changed", kind: .textEdit, page: 2)
        XCTAssertEqual(log.rows(), [.step(0), .group(1..<4), .step(4)])
    }

    func testSaveIsAMilestoneAtTheCursor() {
        var log = HistoryLog()
        log.record("Signature", summary: "Signed", kind: .signature)
        log.saved("Lease_signed.pdf")
        log.record("Date", summary: "Added the date", kind: .text)
        XCTAssertEqual(log.rows().map(\.id).count, 3)
        guard case .save(let save) = log.rows()[1] else { return XCTFail("save row expected") }
        XCTAssertEqual(save.position, 1)
        // Undoing past the save and changing something else drops nothing before it.
        log.undo()
        log.undo()
        log.record("Text", summary: "x", kind: .text)
        XCTAssertTrue(log.saves.isEmpty)
    }

    func testChangeSummaryQuotesTheWordsThatChanged() {
        XCTAssertEqual(HistoryLog.changeSummary(from: "give 24 hours' notice", to: "give 48 hours' notice"),
                       "Changed “24” to “48”")
        XCTAssertEqual(HistoryLog.changeSummary(from: "Unit", to: "Unit 4B"), "Added “4B”")
    }

    // MARK: FindReplace

    func testReplaceTheSecondMatchCaseInsensitively() {
        let text = "Notice is given. Further notice\nmay follow."
        XCTAssertEqual(FindReplace.matches(of: "notice", in: text, caseSensitive: false).count, 2)
        XCTAssertEqual(FindReplace.replace("notice", with: "warning", in: text, occurrence: 1, caseSensitive: false),
                       "Notice is given. Further warning\nmay follow.")
        XCTAssertEqual(FindReplace.matches(of: "notice", in: text, caseSensitive: true).count, 1)
    }

    func testLigaturesAndLineBreaksMatchWhatPDFKitReads() {
        let text = "The landlord will notify the\ntenant in ﬁve days."
        XCTAssertEqual(FindReplace.replace("five", with: "ten", in: text, occurrence: 0, caseSensitive: false),
                       "The landlord will notify the\ntenant in ten days.")
        XCTAssertEqual(FindReplace.matches(of: "the tenant", in: text, caseSensitive: false).count, 1)
    }

    func testNoMatchLeavesTheTextAlone() {
        XCTAssertNil(FindReplace.replace("deposit", with: "x", in: "Rent is due", occurrence: 0, caseSensitive: false))
        let all = FindReplace.replaceAll("deposit", with: "x", in: "Rent is due", caseSensitive: false)
        XCTAssertEqual(all.text, "Rent is due")
        XCTAssertEqual(all.count, 0)
    }

    // MARK: EditSession history

    @MainActor
    func testSessionHistoryMatchesUndoManager() throws {
        let fx = try Fixtures()
        defer { fx.cleanUp() }
        let session = try EditSession(original: fx.textPDF("h.pdf", pages: 1, label: "History"), password: nil)
        defer { session.close() }
        session.undoManager.groupsByEvent = false
        func step(_ body: () -> Void) {
            session.undoManager.beginUndoGrouping()
            body()
            session.undoManager.endUndoGrouping()
        }
        let box = Overlay(page: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 14), rotation: 0, kind: .text(TextBox(text: "A")))
        step { session.add(box, actionName: "Text Box") }
        var moved = box
        moved.rect.origin.x = 30
        step { session.update(moved, actionName: "Move") }
        step { session.remove(box.id) }
        XCTAssertEqual(session.history.entries.map(\.summary), ["Added “A”", "Moved “A”", "Deleted “A”"])
        session.undoManager.undo()
        XCTAssertEqual(session.history.cursor, 2)
        session.undoManager.undo()
        XCTAssertEqual(session.history.cursor, 1)
        session.undoManager.redo()
        XCTAssertEqual(session.history.cursor, 2)
        XCTAssertEqual(session.overlays.first?.rect.minX, 30)

        // A form fill is one step and its undo puts the old values back.
        var fields = ["Email": ""]
        step {
            fields = ["Email": "a@b.c"]
            session.recordFormChange("Fill My Info", summary: "Filled 1 field", page: 0, before: ["Email": ""],
                                     after: ["Email": "a@b.c"]) { fields = $0 }
        }
        XCTAssertEqual(session.history.entries.last?.summary, "Filled 1 field")
        session.undoManager.undo()
        XCTAssertEqual(fields["Email"], "")
        session.undoManager.redo()
        XCTAssertEqual(fields["Email"], "a@b.c")
    }
}
