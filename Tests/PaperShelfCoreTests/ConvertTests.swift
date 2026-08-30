import XCTest
import AppKit
import PDFKit
@testable import PaperShelfCore

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

    /// The external-tool path, run for real against whichever converter this machine has.
    /// Skipped rather than failed where none is installed, since that is the normal case
    /// and the fallback is what covers it.
    func testAnInstalledConverterProducesTheDocumentsWords() throws {
        let installed = availableConverters()
        try XCTSkipIf(installed.isEmpty, "no Markdown converter installed")
        let (converter, tool) = installed[0]

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("converter"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Replicas converge once they agree on the updates.")

        let text = try XCTUnwrap(runConverter(tool: tool, converter: converter, source: file),
                                 "\(converter.name) produced nothing")
        XCTAssertTrue(text.contains("Replicas converge"))
    }

    /// Whatever the converter, the caller gets Markdown and the name of what made it, and
    /// a missing tool is answered by the built-in reader rather than by an error.
    func testMarkdownFallsBackToTheBuiltInReader() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("fallback"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: file, text: "Replicas converge once they agree on the updates.")

        let missing = MarkdownConverter(name: "Nowhere", executable: "papershelf-not-installed",
                                        note: "", arguments: { input, _ in [input.path] })
        let produced = markdown(for: file, passwords: [], using: .external(missing), title: "Paper")

        XCTAssertEqual(produced.tool, "the built-in reader")
        XCTAssertTrue(produced.text.hasPrefix("# Paper"))
        XCTAssertTrue(produced.text.contains("Replicas converge"))
    }

    /// What a stored preference resolves to: the two built-in engines by name, an
    /// external tool by name when it is installed, and automatic for everything else,
    /// including a name whose tool has since been uninstalled.
    func testAStoredNameResolvesToAnEngine() {
        XCTAssertEqual(engine(named: ""), .automatic)
        XCTAssertEqual(engine(named: builtInReaderName), .reader)
        XCTAssertEqual(engine(named: builtInOCRName), .ocr)
        XCTAssertEqual(engine(named: "A Converter Nobody Has"), .automatic,
                       "a tool that is gone is not a worse answer, it is no answer")

        if let best = availableConverters().first?.0 {
            XCTAssertEqual(engine(named: best.name), .external(best))
        }
    }

    /// A scanned page: the words are a picture, so there is no text layer to read. This is
    /// the case every other engine here answers with nothing, and the one the app has to
    /// be able to answer without anything installed.
    private func makeScannedPDF(at url: URL, text: String) throws {
        let size = CGSize(width: 612, height: 792)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            in: NSRect(x: 60, y: 520, width: 500, height: 220),
            withAttributes: [.font: NSFont.systemFont(ofSize: 34),
                             .foregroundColor: NSColor.black])
        image.unlockFocus()

        let raw = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: raw)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        var rect = box
        guard let drawn = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw NSError(domain: "ConvertTests", code: 1)
        }
        context.draw(drawn, in: box)
        context.endPDFPage()
        context.closePDF()
        try (raw as Data).write(to: url)
    }

    private func scratchFolder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName(label), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAScannedPageHasNoTextLayerAndIsReadAnyway() throws {
        let folder = try scratchFolder("scan")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.pdf")
        try makeScannedPDF(at: file, text: "Convergence of replicas")

        XCTAssertFalse(hasReadableText(url: file, passwords: []),
                       "a picture of words carries no text layer")
        XCTAssertFalse(markdownFromPDF(url: file, passwords: [], title: "Scan")
                        .contains("Convergence"),
                       "which is why the reader has nothing to say about it")

        let recognised = markdownFromScan(url: file, passwords: [], title: "Scan")
        XCTAssertTrue(recognised.localizedCaseInsensitiveContains("convergence"),
                      "OCR read: \(recognised)")
        XCTAssertTrue(recognised.hasPrefix("# Scan"))
    }

    /// Automatic is the promise that a document gets the best answer available for it: the
    /// text layer where there is one, recognition where there is not.
    func testAutomaticReadsTheTextLayerAndFallsBackToOCR() throws {
        let folder = try scratchFolder("automatic")
        defer { try? FileManager.default.removeItem(at: folder) }

        let typed = folder.appendingPathComponent("typed.pdf")
        try makeTextPDF(at: typed, text: "Replicas converge once they agree.")
        let scanned = folder.appendingPathComponent("scanned.pdf")
        try makeScannedPDF(at: scanned, text: "Convergence of replicas")

        // With a converter installed, automatic is that converter; the fallback below is
        // what this test is about, so it asks the two built-in engines directly.
        XCTAssertTrue(hasReadableText(url: typed, passwords: []))
        let read = markdown(for: typed, passwords: [], using: .reader)
        XCTAssertTrue(read.text.contains("Replicas converge"))
        XCTAssertEqual(read.tool, "the built-in reader")

        let recognised = markdown(for: scanned, passwords: [], using: .ocr)
        XCTAssertTrue(recognised.text.localizedCaseInsensitiveContains("convergence"))
        XCTAssertEqual(recognised.tool, "the built-in OCR")
    }

    /// A document with a text layer is never sent through recognition: it would be slower
    /// and worse than the words the document already carries.
    func testATypedDocumentIsNotSentThroughOCR() throws {
        let folder = try scratchFolder("typed-only")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("typed.pdf")
        try makeTextPDF(at: file, text: String(repeating: "Convergence and replication. ", count: 8))

        XCTAssertTrue(hasReadableText(url: file, passwords: []))
    }

    /// OCR stops rather than working through a book, and says that it did.
    func testOCRStopsAtItsPageLimitAndSaysSo() throws {
        let folder = try scratchFolder("ocr-limit")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("long.pdf")
        try makeScannedPDF(at: file, text: "Convergence of replicas")
        guard let document = PDFDocument(url: file), let page = document.page(at: 0) else {
            return XCTFail("no page")
        }
        for _ in 0..<3 { document.insert(page.copy() as! PDFPage, at: document.pageCount) }
        document.write(to: file)

        let recognised = markdownFromScan(url: file, passwords: [], title: "Long", pageLimit: 2)

        XCTAssertTrue(recognised.contains("## Page 1"))
        XCTAssertTrue(recognised.contains("## Page 2"))
        XCTAssertFalse(recognised.contains("## Page 3"), "it stopped where it said it would")
        XCTAssertTrue(recognised.contains("Read the first 2 of 4 pages"))
    }
}
