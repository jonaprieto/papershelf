import XCTest
@testable import PDFHammerCore

final class ConvertTests: XCTestCase {

    func testTheBuiltInConversionNeedsNothingInstalled() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: url) }
        try makeTextPDF(at: url, text: String(repeating: "A sentence of the document. ", count: 40))

        let markdown = markdownFromPDF(url: url, passwords: [], title: "A Document")
        XCTAssertTrue(markdown.hasPrefix("# A Document\n"))
        XCTAssertTrue(markdown.contains("## Page 1"))
        XCTAssertTrue(markdown.contains("A sentence of the document."))
    }

    /// A locked file is opened with the passwords it was given, like everything else.
    func testConversionUnlocksWithTheGivenPasswords() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: url) }
        try makeTextPDF(at: url, text: String(repeating: "Sealed but readable. ", count: 40),
                        password: "open-me")

        XCTAssertTrue(markdownFromPDF(url: url, passwords: [], title: "X").hasSuffix("\n\n")
                      || markdownFromPDF(url: url, passwords: [], title: "X") == "# X\n\n",
                      "with no password there is nothing to read")
        XCTAssertTrue(markdownFromPDF(url: url, passwords: ["open-me"], title: "X")
                        .contains("Sealed but readable"))
    }

    func testPageMarkersCanBeLeftOut() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: url) }
        try makeTextPDF(at: url, text: String(repeating: "Body text here. ", count: 40))

        XCTAssertFalse(markdownFromPDF(url: url, passwords: [], pageMarkers: false)
                        .contains("## Page"))
    }

    /// Each converter is invoked the way its own documentation says.
    func testConverterArgumentsMatchEachTool() {
        let input = URL(fileURLWithPath: "/tmp/in/book.pdf")
        let output = URL(fileURLWithPath: "/tmp/out/book.md")
        let byName = Dictionary(uniqueKeysWithValues: markdownConverters.map { ($0.name, $0) })

        XCTAssertEqual(byName["MarkItDown"]?.arguments(input, output),
                       ["/tmp/in/book.pdf", "-o", "/tmp/out/book.md"])
        XCTAssertEqual(byName["pdftotext"]?.arguments(input, output),
                       ["-layout", "/tmp/in/book.pdf", "/tmp/out/book.md"])
        XCTAssertEqual(byName["Marker"]?.arguments(input, output),
                       ["/tmp/in/book.pdf", "--output_dir", "/tmp/out"])
    }

    /// A GUI app inherits launchd's PATH, which holds none of the places these install to,
    /// so looking them up has to be done by hand.
    func testLocateFindsSomethingThatExistsAndNothingThatDoesNot() {
        XCTAssertNil(locate("definitely-not-a-real-tool-\(UUID().uuidString)"))
        // env is in /usr/bin and sh is in /bin: both have to be searched, which is why
        // the first version of this missed /bin entirely.
        XCTAssertEqual(locate("env")?.path, "/usr/bin/env")
        XCTAssertEqual(locate("sh")?.path, "/bin/sh")
    }
}

extension ConvertTests {
    /// Wrapped prose is one paragraph; a contents entry is its own line.
    func testContentsLinesAreNotGluedIntoAParagraph() {
        XCTAssertTrue(isListing("1.2 Sum, Product and Exponential Types . . . . . . . 10"))
        XCTAssertTrue(isListing("9.1 Building Types from a Schema 98"))
        XCTAssertFalse(isListing("the sentence carries on to the following line"))
        XCTAssertFalse(isListing("first published in 2018"),
                       "a sentence can end on a year, and a year is not a page number")
        XCTAssertFalse(isListing("42"), "a bare number is not a listing")
    }
}
