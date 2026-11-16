import XCTest
@testable import Stitch

/// The one Stitch window: ⌘K's matching and renaming a document from its title.
final class OneWindowTests: XCTestCase {
    // MARK: CommandMatch

    func testEveryWordHasToMatch() {
        XCTAssertNotNil(CommandMatch.score("lea", "Lease.pdf"))
        XCTAssertNotNil(CommandMatch.score("merge files", "Merge Files…"))
        XCTAssertNil(CommandMatch.score("merge pdf", "Merge Files…"))
        XCTAssertNil(CommandMatch.score("w9", "W-9 2026.pdf"))
        XCTAssertEqual(CommandMatch.score("  ", "Anything"), 0)
    }

    func testStartOfTitleBeatsStartOfWordBeatsInside() throws {
        let start = try XCTUnwrap(CommandMatch.score("sign", "Signature"))
        let word = try XCTUnwrap(CommandMatch.score("sign", "Create or Change Signature…"))
        let inside = try XCTUnwrap(CommandMatch.score("sign", "Design brief.pdf"))
        XCTAssertGreaterThan(start, word)
        XCTAssertGreaterThan(word, inside)
    }

    func testShorterTitleWinsATie() throws {
        let short = try XCTUnwrap(CommandMatch.score("lease", "Lease.pdf"))
        let long = try XCTUnwrap(CommandMatch.score("lease", "Lease renewal for unit 4B, signed copy.pdf"))
        XCTAssertGreaterThan(short, long)
    }

    func testMatchingIgnoresCase() {
        XCTAssertNotNil(CommandMatch.score("LEASE", "lease.pdf"))
    }

    // MARK: FileRename

    func testRenameKeepsTheNameAndDropsATypedExtension() {
        XCTAssertEqual(FileRename.baseName("Lease – signed", extension: "pdf"), "Lease – signed")
        XCTAssertEqual(FileRename.baseName("Lease signed.pdf", extension: "pdf"), "Lease signed")
        XCTAssertEqual(FileRename.baseName("Lease signed.PDF", extension: "pdf"), "Lease signed")
        XCTAssertEqual(FileRename.baseName("  Lease  ", extension: "pdf"), "Lease")
    }

    func testRenameMakesTheNameSafe() {
        XCTAssertEqual(FileRename.baseName("Rent 1/12: paid", extension: "pdf"), "Rent 1-12- paid")
        XCTAssertEqual(FileRename.baseName("..hidden", extension: "pdf"), "hidden")
        XCTAssertNil(FileRename.baseName("", extension: "pdf"))
        XCTAssertNil(FileRename.baseName("   ", extension: "pdf"))
        XCTAssertNil(FileRename.baseName("...", extension: "pdf"))
        XCTAssertNil(FileRename.baseName(".pdf", extension: "pdf"))
    }

    func testRenameStaysUnderTheFileNameLimit() throws {
        let name = try XCTUnwrap(FileRename.baseName(String(repeating: "é", count: 200), extension: "pdf"))
        XCTAssertLessThanOrEqual(name.utf8.count + ".pdf".utf8.count, 255)
    }
}
