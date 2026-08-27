import XCTest
import SwiftUI
@testable import PDFHammerCore
@testable import PDFHammer

/// A mechanical check for the one layout-bearing change in this pass: tag chips added
/// to `ResultRow`. `NSHostingView` renders the real production view, not a
/// reimplementation of it, at several widths, so a row that would clip or collapse
/// shows up as a wrong size here rather than only in a screenshot nobody looked at.
///
/// This lives in the test target rather than a separate tool because `ResultRow` is
/// `internal` to the `PDFHammer` executable target: only a target inside this package,
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
