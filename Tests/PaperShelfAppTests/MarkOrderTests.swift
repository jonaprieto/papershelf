import XCTest
import PDFKit
import AppKit
@testable import PaperShelf

/// The order the marks are listed in beside the page.
///
/// Neither way marks arrive is in reading order: the scan takes each page's annotations in
/// the order the file stores them, and a new highlight used to be appended, so a passage
/// marked on page 1 was listed under one from page 7.
@MainActor
final class MarkOrderTests: XCTestCase {

    private func mark(page: Int, x: CGFloat, top: CGFloat) -> Annotator.Mark {
        // PDF coordinates grow upwards, so `top` is the y of the line's upper edge.
        let bounds = CGRect(x: x, y: top - 12, width: 100, height: 12)
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        return Annotator.Mark(page: page, kind: "Highlight", quoted: "", note: "",
                              colour: .yellow, annotation: annotation)
    }

    private func order(_ marks: [Annotator.Mark]) -> [String] {
        marks.sorted(by: Annotator.precedes).map {
            "p\($0.page) y\(Int($0.annotation.bounds.maxY)) x\(Int($0.annotation.bounds.minX))"
        }
    }

    func testPagesComeFirst() {
        let out = order([mark(page: 7, x: 0, top: 700), mark(page: 1, x: 0, top: 100)])
        XCTAssertEqual(out, ["p1 y100 x0", "p7 y700 x0"])
    }

    /// Down the page, not up it: a mark near the top of the sheet has the larger y.
    func testWithinAPageTheHigherLineIsFirst() {
        let out = order([mark(page: 3, x: 0, top: 200), mark(page: 3, x: 0, top: 640)])
        XCTAssertEqual(out, ["p3 y640 x0", "p3 y200 x0"])
    }

    /// Two marks on one line are read left to right rather than shuffled by a rounding
    /// difference of half a point in their heights.
    func testTwoMarksOnOneLineGoLeftToRight() {
        let out = order([mark(page: 2, x: 300, top: 500.4), mark(page: 2, x: 60, top: 500)])
        XCTAssertEqual(out, ["p2 y500 x60", "p2 y500 x300"])
    }

    /// The case that was reported: a highlight made after the others still lands where it
    /// sits on the page, not at the end of the list.
    func testANewMarkIsFiledWhereItBelongs() {
        var marks = [mark(page: 1, x: 0, top: 700), mark(page: 3, x: 0, top: 400),
                     mark(page: 7, x: 0, top: 300)]
        marks.append(mark(page: 1, x: 0, top: 500))
        marks.sort(by: Annotator.precedes)
        XCTAssertEqual(marks.map(\.page), [1, 1, 3, 7])
        XCTAssertEqual(marks[1].annotation.bounds.maxY, 500)
    }
}
