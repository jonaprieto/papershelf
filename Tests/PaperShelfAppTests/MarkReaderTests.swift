import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PaperShelf

/// Reading the marks off a document nobody has open. The notes panel used to be able to
/// list highlights only for the file the reader had loaded, which meant a paper on the
/// shelf with nine highlights in it reported nothing.
final class MarkReaderTests: XCTestCase {

    /// A two-page PDF with a findable word on each page, written to a real file: this is
    /// about reading from disk, so a document held in memory would test the wrong thing.
    private func makeFile(words: [String], highlighting: [(page: Int, note: String)]) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for word in words {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: word,
                                   attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for mark in highlighting {
            let page = try XCTUnwrap(document.page(at: mark.page))
            let bounds = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox))).bounds(for: page)
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = .systemYellow
            annotation.contents = mark.note
            page.addAnnotation(annotation)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marks-\(UUID().uuidString).pdf")
        XCTAssertTrue(document.write(to: url), "the fixture has to reach the disk")
        return url
    }

    func testMarksAreReadFromAFileNothingHasOpen() async throws {
        let url = try makeFile(words: ["alpha", "bravo"],
                               highlighting: [(page: 0, note: "worth remembering"), (page: 1, note: "")])
        defer { try? FileManager.default.removeItem(at: url) }

        let marks = await MarkReader.shared.marks(in: url)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.map(\.page), [1, 2], "pages are counted the way a reader counts them")
        XCTAssertEqual(marks.first?.note, "worth remembering")
        XCTAssertEqual(marks.last?.note, "", "a highlight without a note is still a mark")
        XCTAssertTrue(marks.first?.quoted.contains("alpha") ?? false,
                      "the passage under the highlight comes back with it")
    }

    func testAMarkAddedAfterTheFirstReadIsSeen() async throws {
        let url = try makeFile(words: ["alpha", "bravo"], highlighting: [(page: 0, note: "")])
        defer { try? FileManager.default.removeItem(at: url) }

        let before = await MarkReader.shared.marks(in: url)
        XCTAssertEqual(before.count, 1)

        // The same path, written again. The cache is keyed by modification date and size,
        // so the second read has to notice rather than hand back what it remembered.
        let second = try makeFile(words: ["alpha", "bravo"],
                                  highlighting: [(page: 0, note: ""), (page: 1, note: "later")])
        defer { try? FileManager.default.removeItem(at: second) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: second, to: url)

        let after = await MarkReader.shared.marks(in: url)
        XCTAssertEqual(after.count, 2, "the file changed, so the answer changes")
    }

    func testAFileThatIsNotThereHasNoMarksRatherThanAnError() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).pdf")
        let marks = await MarkReader.shared.marks(in: missing)
        XCTAssertTrue(marks.isEmpty, "a volume that went away is an empty list, not a failure")
    }
}
