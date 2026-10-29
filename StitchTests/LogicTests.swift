import XCTest
@testable import Stitch

final class SmartOrderTests: XCTestCase {
    func testLectureNumbersSortNaturally() throws {
        let names = ["Lecture 10", "Lecture 2", "Lecture 1", "Lecture 9"]
        let series = try XCTUnwrap(SmartOrder.series(in: names))
        XCTAssertEqual(series.order.map { names[$0] }, ["Lecture 1", "Lecture 2", "Lecture 9", "Lecture 10"])
        XCTAssertEqual(series.label, "Sorted by lecture number")
        XCTAssertEqual(series.suggestedBaseName, "Lecture 1–10")
    }

    func testNumberInTheMiddle() throws {
        let names = ["Week 12 Slides", "Week 3 Slides"]
        let series = try XCTUnwrap(SmartOrder.series(in: names))
        XCTAssertEqual(series.order.map { names[$0] }, ["Week 3 Slides", "Week 12 Slides"])
        XCTAssertEqual(series.label, "Sorted by week number")
        XCTAssertEqual(series.suggestedBaseName, "Week 3–12 Slides")
    }

    func testSharedNumberIsSkipped() throws {
        let names = ["CS101 Lecture 3", "CS101 Lecture 1", "CS101 Lecture 2"]
        let series = try XCTUnwrap(SmartOrder.series(in: names))
        XCTAssertEqual(series.order.map { names[$0] }, ["CS101 Lecture 1", "CS101 Lecture 2", "CS101 Lecture 3"])
        XCTAssertEqual(series.label, "Sorted by lecture number")
        XCTAssertEqual(series.suggestedBaseName, "CS101 Lecture 1–3")
    }

    func testDifferentTitlesAfterTheNumberStillCount() throws {
        let names = ["Lecture 2 - Recursion", "lecture_1 - Intro"]
        let series = try XCTUnwrap(SmartOrder.series(in: names))
        XCTAssertEqual(series.order, [1, 0])
    }

    func testLeadingZerosAndRangeKeepTheirDigits() throws {
        let names = ["Scan 007", "Scan 010", "Scan 001"]
        let series = try XCTUnwrap(SmartOrder.series(in: names))
        XCTAssertEqual(series.suggestedBaseName, "Scan 001–010")
    }

    func testNoSeriesKeepsAddedOrder() {
        XCTAssertNil(SmartOrder.series(in: ["Lecture 1", "Case Notes", "Problem Set 3"]))
        XCTAssertNil(SmartOrder.series(in: ["Lecture 1"]))
        XCTAssertNil(SmartOrder.series(in: ["Lecture 1", "Lecture 1"]))
        XCTAssertNil(SmartOrder.series(in: ["Lecture 1", "Week 2"]))
        XCTAssertNil(SmartOrder.series(in: ["Notes", "Summary"]))
    }

    func testNumbersOnly() throws {
        let series = try XCTUnwrap(SmartOrder.series(in: ["2", "10", "1"]))
        XCTAssertEqual(series.order, [2, 0, 1])
        XCTAssertEqual(series.label, "Sorted by number")
    }
}

final class OutputNamingTests: XCTestCase {
    func testSuggestion() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-21T13:52:00Z"))
        let local = OutputNaming.timestamp(date)
        XCTAssertEqual(OutputNaming.suggestion(baseNames: ["a", "b"], series: nil, date: date), "Merged – \(local).pdf")
        XCTAssertEqual(OutputNaming.suggestion(baseNames: ["Report"], series: nil), "Report.pdf")
        let series = SmartOrder.series(in: ["Lecture 1", "Lecture 3"])
        XCTAssertEqual(OutputNaming.suggestion(baseNames: ["Lecture 1", "Lecture 3"], series: series), "Lecture 1–3.pdf")
    }

    func testTimestampFormat() {
        XCTAssertNotNil(OutputNaming.timestamp().wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{4}/))
    }

    func testBaseName() {
        XCTAssertEqual(OutputNaming.baseName(of: "Lecture 1–3.pdf"), "Lecture 1–3")
        XCTAssertEqual(OutputNaming.baseName(of: "photo.JPG"), "photo")
        XCTAssertEqual(OutputNaming.baseName(of: "  notes  "), "notes")
        XCTAssertEqual(OutputNaming.baseName(of: "a/b:c"), "a-b-c")
        XCTAssertEqual(OutputNaming.baseName(of: ".pdf"), "Untitled")
        XCTAssertEqual(OutputNaming.baseName(of: "..hidden"), "hidden")
        XCTAssertEqual(OutputNaming.baseName(of: "v1.2 draft"), "v1.2 draft")
    }

    func testUniqueURLNeverOverwrites() {
        let folder = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let taken: Set<String> = ["/tmp/out/Merged.pdf", "/tmp/out/Merged (2).pdf"]
        let url = OutputNaming.uniqueURL(in: folder, base: "Merged", ext: "pdf") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "Merged (3).pdf")
        let free = OutputNaming.uniqueURL(in: folder, base: "Other", ext: "pdf") { taken.contains($0.path) }
        XCTAssertEqual(free.lastPathComponent, "Other.pdf")
        let dir = OutputNaming.uniqueURL(in: folder, base: "Converted", ext: nil) { _ in false }
        XCTAssertEqual(dir.lastPathComponent, "Converted")
    }
}

final class FileKindTests: XCTestCase {
    func testClassify() {
        func kind(_ name: String) -> FileKind? { FileKind.classify(URL(fileURLWithPath: "/x/\(name)")) }
        XCTAssertEqual(kind("a.pdf"), .pdf)
        XCTAssertEqual(kind("a.PDF"), .pdf)
        XCTAssertEqual(kind("IMG_1.HEIC"), .image(jpeg: false))
        XCTAssertEqual(kind("a.png"), .image(jpeg: false))
        XCTAssertEqual(kind("a.jpg"), .image(jpeg: true))
        XCTAssertEqual(kind("a.jpeg"), .image(jpeg: true))
        XCTAssertEqual(kind("a.docx"), .word)
        XCTAssertEqual(kind("a.pptx"), .powerpoint)
        XCTAssertNil(kind("a.txt"))
        XCTAssertNil(kind("a.zip"))
        XCTAssertNil(kind("noextension"))
    }
}

final class ArrangementTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testSmallSetsStartFullyExpanded() {
        let arr = Arrangement(files: [(a, 3), (b, 1)])
        XCTAssertEqual(arr.items.count, 4)
        XCTAssertFalse(arr.hasStacks)
        XCTAssertEqual(arr.pages.map(\.index), [0, 1, 2, 0])
    }

    func testLargeSetsStartAsFileTiles() {
        let arr = Arrangement(files: [(a, 12), (b, 1), (c, 10)])
        XCTAssertEqual(arr.items.count, 3)
        XCTAssertTrue(arr.items[0].isStack)
        XCTAssertFalse(arr.items[1].isStack)   // a one-page file is just a page
        XCTAssertEqual(arr.pageCount, 23)
    }

    func testMoveBeforeAndAfter() {
        var arr = Arrangement(files: [(a, 1), (b, 1), (c, 1)])
        let ids = arr.items.map(\.id)
        arr.move(ids[2], to: ids[0], before: true)
        XCTAssertEqual(arr.items.map(\.fileID), [c, a, b])
        arr.move(ids[2], to: ids[1], before: false)
        XCTAssertEqual(arr.items.map(\.fileID), [a, b, c])
        arr.move(ids[0], to: ids[0], before: true)
        XCTAssertEqual(arr.items.map(\.fileID), [a, b, c])
    }

    func testRemoveExpandCollapse() {
        var arr = Arrangement(files: [(a, 10), (b, 10)])
        XCTAssertEqual(arr.items.count, 2)
        arr.expand(a)
        XCTAssertEqual(arr.items.count, 11)
        // Move a page of `a` after `b`, remove another, then regroup: the moved page joins at a's first spot.
        let bTile = arr.items.last!.id
        arr.move(arr.items[0].id, to: bTile, before: false)
        arr.remove(arr.items[0].id)
        arr.collapse(a)
        XCTAssertEqual(arr.items.count, 2)
        XCTAssertEqual(arr.items[0].pages.map(\.index), [2, 3, 4, 5, 6, 7, 8, 9, 0])
        arr.expandAll()
        XCTAssertFalse(arr.hasStacks)
        arr.collapseAll()
        XCTAssertEqual(arr.items.count, 2)
        arr.remove(arr.items[1].id)
        XCTAssertEqual(arr.pageCount, 9)
    }

    func testRemovedPagesStayRemovedOnRebuild() {
        let removed: Set = [PageRef(fileID: a, index: 1)]
        let arr = Arrangement(files: [(a, 3)], removed: removed)
        XCTAssertEqual(arr.pages.map(\.index), [0, 2])
    }
}
