import XCTest
@testable import PaperShelf

/// The two sentences the status bar says about the document being read. A bar about one
/// document and a bar about a collection are not the same bar, and these are the strings
/// that make it the first kind.
final class StatusBarDocumentTests: XCTestCase {

    private func facts(bytes: Int? = 19_293_798, pages: Int = 248, locked: Bool = false,
                       highlights: Int = 14, notes: Int = 4) -> StatusBar.DocumentFacts {
        StatusBar.DocumentFacts(path: "/tmp/a.pdf", bytes: bytes, pages: pages,
                                locked: locked, highlights: highlights, notes: notes)
    }

    func testSizePagesAndWhetherItOpened() {
        let physical = facts().physical
        XCTAssertTrue(physical.hasSuffix("· 248 pages · unlocked"), physical)
        XCTAssertTrue(physical.contains("MB"), physical)
        XCTAssertTrue(facts(locked: true).physical.hasSuffix("· unlocked") == false)
        XCTAssertTrue(facts(locked: true).physical.hasSuffix("· locked"))
    }

    /// A file whose size was never read says nothing about it rather than "0 bytes", and
    /// a document of one page is not "1 pages".
    func testWhatIsUnknownIsLeftOutAndOneIsSingular() {
        XCTAssertEqual(facts(bytes: nil, pages: 1).physical, "1 page · unlocked")
        XCTAssertEqual(facts(bytes: nil, pages: 0).physical, "unlocked")
    }

    func testMarksAreCountedTheTwoWaysAReaderCountsThem() {
        XCTAssertEqual(facts().marks, "14 highlights · 4 notes")
        XCTAssertEqual(facts(highlights: 1, notes: 1).marks, "1 highlight · 1 note")
        XCTAssertEqual(facts(highlights: 0, notes: 0).marks, "0 highlights · 0 notes")
    }
}
