import XCTest
@testable import PDFHammerCore

final class ActivityTests: XCTestCase {

    private let moment = Date(timeIntervalSince1970: 1_756_000_000)

    func testEachLineCarriesTimeKindAndSubject() {
        let text = logText([
            LogEntry(at: moment, kind: .renamed, subject: "bank/Extracto.pdf",
                     detail: "-> 2024-06-extracto.pdf"),
            LogEntry(at: moment, kind: .trashed, subject: "junk.pdf"),
        ])
        let lines = text.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("renamed"))
        XCTAssertTrue(lines[0].contains("bank/Extracto.pdf"))
        XCTAssertTrue(lines[0].hasSuffix("-> 2024-06-extracto.pdf"))
        XCTAssertTrue(lines[1].hasSuffix("junk.pdf"), "no detail means no trailing spaces")
    }

    /// The kinds are padded to a common width so the subjects line up in a column.
    func testKindsAreAligned() {
        let text = logText([
            LogEntry(at: moment, kind: .moved, subject: "a.pdf"),
            LogEntry(at: moment, kind: .decrypted, subject: "b.pdf"),
        ])
        let lines = text.split(separator: "\n").map(String.init)
        let columns = lines.map { $0.range(of: ".pdf")!.lowerBound }
        XCTAssertEqual(columns[0], columns[1])
    }

    func testEmptyLogRendersEmpty() {
        XCTAssertEqual(logText([]), "")
    }
}
