import XCTest
import SwiftUI
@testable import PaperShelfCore
@testable import PaperShelf

/// A mechanical check for the one layout-bearing change in this pass: tag chips added
/// to `ResultRow`. `NSHostingView` renders the real production view, not a
/// reimplementation of it, at several widths, so a row that would clip or collapse
/// shows up as a wrong size here rather than only in a screenshot nobody looked at.
///
/// This lives in the test target rather than a separate tool because `ResultRow` is
/// `internal` to the `PaperShelf` executable target: only a target inside this package,
/// built with testability on (which `swift test` already turns on for every target),
/// can see it at all. A genuinely external harness would have to relink against
/// SwiftPM's own "testable executable" product, which is not something SwiftPM exposes
/// as a stable, scriptable interface.
@MainActor
final class CatalogueLayoutTests: XCTestCase {

    /// Hosts the view in a real (offscreen) window before measuring: some SwiftUI
    /// layout, text measurement in particular, does not settle correctly on a bare
    /// `NSHostingView` that was never attached to a window.
    private func size(of view: some View, width: CGFloat) -> CGSize {
        let hosting = NSHostingView(rootView: view.frame(width: width, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    private func makeItem(_ name: String) -> Item {
        let root = URL(fileURLWithPath: "/tmp/shelf")
        let url = root.appendingPathComponent(name)
        return Item(root: root, source: url, destination: url, status: .renamed)
    }

    /// Standing in for the sidebar's usual range, from the narrowest the split allows up
    /// to a wide window.
    private let widths: [CGFloat] = [220, 320, 480, 800]

    func testATaggedRowIsNeverShorterThanTheSameRowWithoutTags() {
        let item = makeItem("statement.pdf")
        for width in widths {
            let bare = size(of: ResultRow(item: item, decision: nil, duplicate: nil), width: width)
            let tagged = size(of: ResultRow(item: item, decision: nil, duplicate: nil,
                                            tags: ["Reading", "Bank", "2024"]),
                              width: width)
            XCTAssertGreaterThan(bare.height, 0, "at width \(width)")
            XCTAssertGreaterThan(tagged.height, 0, "at width \(width)")
            XCTAssertGreaterThan(tagged.height, bare.height,
                                 "a row of chips must add visible height over the untagged row, at width \(width)")
        }
    }

    /// A single very long tag name must wrap or truncate within the row's own width
    /// rather than pushing it wider than what it was asked to fit in.
    func testATagChipDoesNotWidenTheRowBeyondWhatWasAsked() {
        let item = makeItem("statement.pdf")
        for width in widths {
            let measured = size(of: ResultRow(item: item, decision: nil, duplicate: nil,
                                              tags: ["An Unreasonably Long Tag Name Someone Typed"]),
                                width: width)
            XCTAssertLessThanOrEqual(measured.width, width + 1, "at width \(width)")
        }
    }

    func testManyTagsStillProduceAFiniteHeight() {
        let item = makeItem("statement.pdf")
        let many = (1...12).map { "tag\($0)" }
        for width in widths {
            let measured = size(of: ResultRow(item: item, decision: nil, duplicate: nil, tags: many), width: width)
            XCTAssertTrue(measured.height.isFinite && measured.height > 0, "at width \(width)")
            XCTAssertLessThanOrEqual(measured.width, width + 1, "at width \(width)")
        }
    }
}

// MARK: - Covers keep a book's proportions

/// The cover used to be 168 points tall whatever the card measured, so a tall book sat in
/// a letterbox with grey above and below it and a wide one was cropped. The band was a
/// constant and a book is not.
extension CatalogueLayoutTests {

    func testShelfColumnsIncludeTheGridPadding() {
        XCTAssertEqual(Metric.catalogueColumns(for: 390), 1)
        XCTAssertEqual(Metric.catalogueColumns(for: 406), 2)
        XCTAssertEqual(Metric.catalogueColumns(for: 800), 4)
    }

    func testCoverHeightFollowsTheWidth() {
        XCTAssertEqual(Metric.coverHeight(forWidth: 100), 129)
        XCTAssertEqual(Metric.coverHeight(forWidth: 176), 228)
        XCTAssertEqual(Metric.coverHeight(forWidth: 200), 259)
    }

    /// The box has to be at least as wide as the widest page anybody shelves, or that page
    /// fits by width, stops short of the box's height, and stands lower than the card
    /// beside it with its title lower too. That is the bug the ratio exists to prevent, so
    /// it is the ratio that gets asserted rather than the number.
    ///
    /// A page fills the box's height exactly when its own height-over-width is at least
    /// the box's. Absolute size does not come into it: a cover is scaled to the box, so an
    /// A5 page and an A3 one draw the same thumbnail -- the A series all share the same
    /// ratio. What does not fill the box is anything *wider* than letter, and those are
    /// centred in it rather than cropped to fit: a 16:9 slide squeezed into a portrait box
    /// is a vertical slice out of the middle of a slide, which is not a picture of the
    /// document.
    func testEveryOrdinaryPageFillsTheCoverBox() {
        func fillsHeight(_ pageAspect: CGFloat) -> Bool { pageAspect >= Metric.coverAspect }

        XCTAssertTrue(fillsHeight(11.0 / 8.5), "US Letter")
        XCTAssertTrue(fillsHeight(14.0 / 8.5), "US Legal")
        for (name, short, long) in [("A3", 297.0, 420.0), ("A4", 210.0, 297.0),
                                    ("A5", 148.0, 210.0), ("A6", 105.0, 148.0),
                                    ("B5", 176.0, 250.0)] {
            XCTAssertTrue(fillsHeight(long / short), "\(name) portrait")
        }

        // Deliberately not: a document that is wider than paper is drawn as what it is.
        XCTAssertFalse(fillsHeight(1.0), "a square scan")
        XCTAssertFalse(fillsHeight(3.0 / 4.0), "4:3 slides")
        XCTAssertFalse(fillsHeight(9.0 / 16.0), "16:9 slides")
    }

    /// A grid mid-resize will propose nonsense; a negative frame is a crash, not a layout.
    func testCoverHeightRefusesToGoNegative() {
        XCTAssertEqual(Metric.coverHeight(forWidth: 0), 0)
        XCTAssertEqual(Metric.coverHeight(forWidth: -40), 0)
    }

    func testWiderCardsAreNeverShorter() {
        var previous: CGFloat = 0
        for width in stride(from: CGFloat(20), through: 400, by: 20) {
            let height = Metric.coverHeight(forWidth: width)
            XCTAssertGreaterThanOrEqual(height, previous)
            previous = height
        }
    }

    /// The raster is asked for at the size a card draws at, doubled for retina, rather
    /// than the flat 320 it used to be — which on a dense shelf is a lot of pixels
    /// rendered in order to be thrown away.
    func testCoversAreRasterisedAtTheSizeTheyAreDrawn() {
        XCTAssertEqual(CoverCard.rasterHeight, Metric.coverHeight(forWidth: Metric.coverWidth) * 2)
    }
}
