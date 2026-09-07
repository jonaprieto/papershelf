import XCTest
import SwiftUI
import PDFKit
@testable import PaperShelfCore
@testable import PaperShelf

/// The pane reads the outline's width off the room the pane itself got, not off a
/// constant, so that on a pane too narrow for both it is the chapter list that narrows
/// and not the page. A constant width there costs nothing that a screenshot of a wide
/// window would show, and turns the page into a thumbnail on a narrow one, so what is
/// measured here is the page AppKit actually laid out at widths a pane really takes.
@MainActor
final class DocumentPaneLayoutTests: XCTestCase {

    /// The hosted PDF view, which is the page.
    private func hostedPage(_ view: NSView) -> PDFView? {
        if let page = view as? PDFView { return page }
        for sub in view.subviews {
            if let page = hostedPage(sub) { return page }
        }
        return nil
    }

    /// The marker overlay, wherever the pane put it.
    private func hostedMarker(_ view: NSView) -> MarkerView? {
        if let marker = view as? MarkerView { return marker }
        for sub in view.subviews {
            if let marker = hostedMarker(sub) { return marker }
        }
        return nil
    }

    private func pane<Overlay: View>(contentsRail: Bool,
                                     @ViewBuilder overlays: @escaping () -> Overlay)
    -> some View {
        DocumentPane(url: URL(fileURLWithPath: "/nonexistent/paper.pdf"),
                     passwords: [],
                     annotator: Annotator(),
                     fit: .constant(.width),
                     appearance: .normal,
                     showsContentsRail: contentsRail,
                     openFind: {},
                     overlays: overlays)
    }

    /// Hosts a view in a real (offscreen) window at `width` and hands the laid-out host
    /// to `measure`. A window is needed rather than a bare `NSHostingView`: SwiftUI does
    /// not lay a hosted AppKit view out until it is attached to one.
    private func hosted<T>(_ view: some View, width: CGFloat,
                           measure: @MainActor (NSView) -> T) -> T {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return measure(hosting)
    }

    /// The corner SwiftUI calls top-leading, read in the host's own geometry. Which edge
    /// that is depends on the host: an unflipped view counts up from the bottom, and the
    /// same numbers would then read as a pass for an overlay parked at the wrong corner.
    private func topLeading(of view: NSView, in host: NSView) -> CGPoint {
        let rect = view.convert(view.bounds, to: host)
        return CGPoint(x: rect.minX, y: host.isFlipped ? rect.minY : rect.maxY)
    }

    /// Where the page landed inside a pane of the given width.
    private func pageRect(contentsRail: Bool, width: CGFloat) -> CGRect {
        hosted(pane(contentsRail: contentsRail, overlays: { EmptyView() }), width: width) { host in
            guard let page = hostedPage(host) else { return .null }
            return page.convert(page.bounds, to: host)
        }
    }

    /// The widths a pane can really be: a 13 inch shelf's document region split in two,
    /// a third of one, half of one, and the whole region on a laptop.
    private let widths: [CGFloat] = [328, 400, 647, 1176]

    func testThePageKeepsItsFloorWithTheOutlineBesideIt() {
        // The divider between them is the one point the page does not get.
        let floor = SplitLayout.previewFloorBesideContents - SplitLayout.dividerBeforeInspector
        for width in widths {
            let page = pageRect(contentsRail: true, width: width)
            XCTAssertGreaterThanOrEqual(page.width, floor - 0.5,
                                        "at pane width \(width) the page got \(page.width)")
            XCTAssertLessThanOrEqual(page.maxX, width + 0.5,
                                     "at pane width \(width) the page reached \(page.maxX)")
        }
    }

    /// The rail gives way before the page does, which is what `contentsRailWidth` is for.
    /// Asking for it at a width that leaves the page under its floor must draw no rail
    /// rather than a rail that leaves the page a strip.
    func testTheRailIsNotDrawnWhereThePageWouldHaveNoRoom() {
        let narrow = SplitLayout.previewFloorBesideContents - 40
        XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: narrow), 0)
        let page = pageRect(contentsRail: true, width: narrow)
        XCTAssertGreaterThanOrEqual(page.width, narrow - SplitLayout.dividerBeforeInspector - 0.5,
                                    "the rail took \(narrow - page.width) of a pane that had none to give")
        XCTAssertLessThanOrEqual(page.maxX, narrow + 0.5, "the page reached \(page.maxX)")
    }

    /// Once the rail has narrowed to nothing there is nothing left for a divider to
    /// divide, so the page starts at the pane's own edge and gets the whole of it. Keeping
    /// the divider drew a line down the left of the page with no rail behind it, which is
    /// what a reader window at its 520 point floor with the notes open actually showed.
    func testNoDividerIsDrawnAheadOfAPageWithNoRailBesideIt() {
        // Every width here is one where the ramp has already reached zero: below the
        // page's floor, and at it.
        for width in [200, 260, SplitLayout.previewFloorBesideContents] as [CGFloat] {
            XCTAssertEqual(SplitLayout.contentsRailWidth(inspectorWidth: width), 0,
                           "at pane width \(width) the rail is not the case under test")
            let page = pageRect(contentsRail: true, width: width)
            XCTAssertEqual(page.minX, 0, accuracy: 0.5,
                           "at pane width \(width) the page starts at x \(page.minX), "
                           + "so something is drawn ahead of it")
            XCTAssertEqual(page.width, width, accuracy: 0.5,
                           "at pane width \(width) the page got \(page.width)")
        }
    }

    /// What a host hands in through `overlays` is bars that belong against the corners of
    /// the page, and one of them, the label on a document that will not open, is only as
    /// big as its own text. So the pane has to hand the overlay the page's top-leading
    /// corner and leave it at its own size. Centring it instead moved that label halfway
    /// down the page with nothing else to show for it.
    func testAnOverlayIsPlacedAtThePagesTopLeadingCorner() {
        // Small enough that a centred overlay lands hundreds of points from this corner.
        let size = CGSize(width: 40, height: 20)
        // With the rail beside it the page does not start at the pane's own origin, so a
        // corner that only looks right against the window would show up here.
        let placed = hosted(pane(contentsRail: true,
                                 overlays: { Marker().frame(width: size.width, height: size.height) }),
                            width: 1176) { host -> (page: CGPoint, marker: CGPoint, size: CGSize)? in
            guard let page = hostedPage(host), let marker = hostedMarker(host) else { return nil }
            return (topLeading(of: page, in: host),
                    topLeading(of: marker, in: host),
                    marker.bounds.size)
        }
        guard let placed else { return XCTFail("the pane drew no page, or drew no overlay") }
        XCTAssertEqual(placed.size.width, size.width, accuracy: 0.5,
                       "the overlay was drawn \(placed.size.width) wide, not the \(size.width) it asked for")
        XCTAssertEqual(placed.size.height, size.height, accuracy: 0.5,
                       "the overlay was drawn \(placed.size.height) tall, not the \(size.height) it asked for")
        XCTAssertEqual(placed.marker.x, placed.page.x, accuracy: 0.5,
                       "the overlay starts at x \(placed.marker.x), the page at \(placed.page.x)")
        XCTAssertEqual(placed.marker.y, placed.page.y, accuracy: 0.5,
                       "the overlay starts at y \(placed.marker.y), the page at \(placed.page.y)")
    }
}

/// An overlay of a known size, hosted as an AppKit view so that the same walk of the tree
/// that finds the page can find it and say where the pane put it. A SwiftUI shape would
/// draw into a layer with no view of its own to ask.
private final class MarkerView: NSView {}

private struct Marker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}
}
