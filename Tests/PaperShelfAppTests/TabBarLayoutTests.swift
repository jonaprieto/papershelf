import XCTest
import SwiftUI
@testable import PaperShelf

/// The filter bar in this app was an HStack of fixed-size children, and when it ran out of
/// room it drew them past its own frame and over the pane beside it while reporting an
/// ordinary size. A tab bar is the same shape and a pane can be 328 points wide, so this
/// measures what is painted rather than what is reported.
///
/// Painted here means the pixels, not the view tree. A walk of the AppKit tree measures
/// where views were laid out, and a scroll view lays its content out at the content's own
/// width and then clips it: twelve tabs in a 1176 point bar put a document view 996 points
/// past the bar's edge that nobody ever sees. So the bar is drawn into a bitmap with empty
/// room beside it, the way it sits in a window with a pane beside it, and what is measured
/// is how far the ink actually reached.
@MainActor
final class TabBarLayoutTests: XCTestCase {

    /// The room beside the bar. An overflowing bar needs somewhere to overflow into: hosted
    /// at exactly its own size it is clipped by the host itself, and then a bar painting
    /// over its neighbour and a bar behaving perfectly measure the same.
    private static let beside: CGFloat = 600

    /// Draws the bar at `width` into an offscreen window and hands back its pixels. A real
    /// window rather than a bare `NSHostingView`: SwiftUI does not settle text measurement
    /// or lay a hosted AppKit view out until it is attached to one.
    private func render(_ view: some View, width: CGFloat) -> NSBitmapImageRep? {
        let total = width + Self.beside
        let content = HStack(spacing: 0) {
            view.frame(width: width, height: TabBar.height)
            Spacer(minLength: 0)
        }
        .frame(width: total, height: TabBar.height, alignment: .leading)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: total,
                                                 height: TabBar.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// How far past its own width the bar painted, in points. Negative means it stopped
    /// short, which a scrolled bar at a wide window does.
    private func overflow(of view: some View, width: CGFloat) -> CGFloat {
        let total = width + Self.beside
        // A render that could not be made is not a bar that fits: it is a measurement that
        // did not happen, and it fails rather than passing quietly.
        guard let rep = render(view, width: width) else { return .greatestFiniteMagnitude }
        var edge: CGFloat = 0
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                edge = CGFloat(x + 1) / CGFloat(rep.pixelsWide) * total
                break
            }
            if edge > 0 { break }
        }
        return edge - width
    }

    /// The rightmost point at which two renders differ, or zero where they are the same
    /// pixel for pixel. This is what a bar's tabs are worth on screen: the background and
    /// the room beside it are identical in both, so what is left is the tabs themselves.
    private func rightmostDifference(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?,
                                     total: CGFloat) -> CGFloat {
        guard let a, let b, let left = a.bitmapData, let right = b.bitmapData,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              a.bytesPerRow == b.bytesPerRow else { return 0 }
        let bytesPerPixel = a.bitsPerPixel / 8
        for x in stride(from: a.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<a.pixelsHigh {
                let at = y * a.bytesPerRow + x * bytesPerPixel
                for byte in 0..<bytesPerPixel where left[at + byte] != right[at + byte] {
                    return CGFloat(x + 1) / CGFloat(a.pixelsWide) * total
                }
            }
        }
        return 0
    }

    /// How many pixel columns two renders disagree about between two points across them.
    /// `rightmostDifference` answers where the last one is, which says nothing about a
    /// region that has to be looked at on its own, such as the square the + sits in.
    ///
    /// A pair that cannot be compared counts as every column: a measurement that did not
    /// happen is not a pair that matched.
    private func differingColumns(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?,
                                  from: CGFloat, to: CGFloat, total: CGFloat) -> Int {
        guard let a, let b, let left = a.bitmapData, let right = b.bitmapData,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              a.bytesPerRow == b.bytesPerRow else { return .max }
        let bytesPerPixel = a.bitsPerPixel / 8
        var differing = 0
        for x in columns(of: a, from: from, to: to, total: total) {
            for y in 0..<a.pixelsHigh {
                let at = y * a.bytesPerRow + x * bytesPerPixel
                if (0..<bytesPerPixel).contains(where: { left[at + $0] != right[at + $0] }) {
                    differing += 1
                    break
                }
            }
        }
        return differing
    }

    /// The pixel columns covering a span given in points. The bar is described in points
    /// and the bitmap is drawn at whatever scale the machine running this has, so the two
    /// are not the same number and only one of them is worth writing a test in.
    private func columns(of rep: NSBitmapImageRep, from: CGFloat, to: CGFloat,
                         total: CGFloat) -> Range<Int> {
        let scale = CGFloat(rep.pixelsWide) / total
        let first = max(0, Int((from * scale).rounded(.up)))
        let last = min(rep.pixelsWide, Int((to * scale).rounded(.down)))
        return first..<max(first, last)
    }

    /// The bar's background carrying nothing at all.
    ///
    /// The material is opaque and covers the bar's whole width, so asking whether anything
    /// is painted in a given square is answered yes by the background on its own. What
    /// differencing against this control leaves is what was painted onto the material,
    /// which is the only way to see the + rather than the bar under it. It repeats the
    /// bar's background chain; the check that uses it is two-sided so that a control which
    /// has drifted out of step with the bar reads as every column differing rather than as
    /// a + that is present.
    private var backdrop: some View {
        Color.clear
            .frame(height: TabBar.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .clipped()
    }

    private func bar(_ count: Int) -> some View {
        let tabs = (0..<count).map {
            Deck.Tab(id: UUID(), key: "/library/paper-\($0).pdf",
                     isPreview: false, annotator: Annotator())
        }
        return TabBar(tabs: tabs, active: tabs.first?.id,
                      title: { _ in "2017-gomes-verifying-strong-eventual-consistency.pdf" },
                      activate: { _ in }, close: { _ in }, open: {})
    }

    /// A 13 inch shelf's document region split in two is about 328 points, the window's own
    /// floor leaves 360, and a maximised reader gets the rest.
    private let widths: [CGFloat] = [260, 328, 360, 647, 1176]

    func testTheBarStaysInsideItsOwnWidthHoweverManyTabsThereAre() {
        for width in widths {
            for count in [1, 2, 5, 12] {
                XCTAssertLessThanOrEqual(overflow(of: bar(count), width: width), 0.5,
                                         "\(count) tabs at width \(width)")
            }
        }
    }

    func testOneTabWithAVeryLongNameStaysInside() {
        XCTAssertLessThanOrEqual(overflow(of: bar(1), width: 260), 0.5)
    }

    /// A check that only asks where a view stops also passes on a view that draws nothing,
    /// and this repository has shipped that kind of check before. So the same renders are
    /// asked what the bar put on screen: five tabs paint several hundred points that the
    /// same bar with none does not, and they paint them side by side. A bar that drew its
    /// background and no tabs, or drew one tab whatever it was given, or drew nothing at
    /// all, differs from an empty one by nothing or by one tab's worth.
    func testEveryTabIsDrawn() {
        let width: CGFloat = 1176
        let total = width + Self.beside
        let empty = render(bar(0), width: width)
        let one = rightmostDifference(render(bar(1), width: width), empty, total: total)
        let five = rightmostDifference(render(bar(5), width: width), empty, total: total)
        XCTAssertGreaterThan(one, 100, "a bar with one tab painted \(one) points of it")
        XCTAssertGreaterThan(five, 4 * one,
                             "five tabs reached \(five), one tab \(one), so they are not "
                             + "standing beside each other")
    }

    /// The + is pinned to the trailing edge, and it is still there once the tabs overflow.
    ///
    /// Two things at once, because either on its own passes on a bar that is broken. The
    /// trailing square of a bar with one tab has something painted onto its material, so a
    /// + that was never drawn, or that the tabs' width pushed past the trailing edge where
    /// the bar's own clip erases it, fails here. And that square holds the same pixels at
    /// twelve tabs as at one, so a + carried along inside the scroll view fails too, since
    /// an overflowing bar scrolls it out of the square and leaves tab text in its place.
    ///
    /// A point is left at the leading side of the square so that what is measured is the
    /// button and not the scroll view's clip boundary beside it. One tab is the case that
    /// carries the first check: a tab is at most 180 points wide, so at every width here it
    /// stops well short of the square and cannot be mistaken for the +.
    func testThePlusIsPinnedAtTheTrailingEdgeHoweverManyTabsThereAre() throws {
        for width in widths {
            let total = width + Self.beside
            let square = width - TabBar.height + 1
            let plain = render(backdrop, width: width)
            let alone = try XCTUnwrap(render(bar(1), width: width))
            let all = columns(of: alone, from: square, to: width, total: total).count
            let drawn = differingColumns(alone, plain, from: square, to: width, total: total)
            XCTAssertTrue(drawn > 0 && drawn < all,
                          "a \(width) point bar with one tab painted \(drawn) of the \(all) "
                          + "columns in its trailing square; a + is some of them, not none and "
                          + "not all of them")
            for count in [2, 5, 12] {
                let crowded = render(bar(count), width: width)
                XCTAssertEqual(
                    differingColumns(alone, crowded, from: square, to: width, total: total), 0,
                    "\(count) tabs at width \(width) changed what the trailing square holds, "
                    + "so the + travels with the tabs rather than staying put")
            }
        }
    }
}
