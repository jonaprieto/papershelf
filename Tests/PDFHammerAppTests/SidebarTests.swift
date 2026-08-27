import XCTest
import SwiftUI
import AppKit
@testable import PDFHammer

/// The rail must never disappear on a narrow window, and the tabs it switches between must
/// all still be reachable.
@MainActor
final class SidebarTests: XCTestCase {

    override class func setUp() {
        // `rail` reaches `Library.shared`, a lazily-opened connection to the real store at
        // its default location. Redirecting it to a scratch path before anything can force
        // that lazy `static let` keeps this test off the library a person keeps their books
        // in. Guarded, since another file in this target may have set its own override.
        if getenv("PDFHAMMER_LIBRARY_PATH") == nil {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdfhammer-sidebar-tests-\(UUID().uuidString).sqlite")
            setenv("PDFHAMMER_LIBRARY_PATH", scratch.path, 1)
        }
    }

    // MARK: - Rail tabs

    /// A tab silently dropped from `allCases`, or renamed without updating this, breaks
    /// here first.
    func testRailTabsAreAllStillThere() {
        let expected: [SidebarTab] = [
            .sources, .explorer, .passwords, .naming, .files,
            .ai, .bibtex, .tags, .library, .reading, .log, .appearance,
        ]
        XCTAssertEqual(SidebarTab.allCases, expected)
    }

    func testEveryTabHasItsOwnIcon() {
        let icons = SidebarTab.allCases.map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count, "two tabs share an icon")
        XCTAssertEqual(SidebarTab.explorer.icon, "list.bullet.indent")
        XCTAssertEqual(SidebarTab.tags.icon, "tag")
    }

    // MARK: - Rail width under a squeeze

    /// `ContentView.body` keeps `rail` out of the `NavigationSplitView` entirely, in an
    /// `HStack` beside it, so a window too narrow for both split-view columns collapses the
    /// panel rather than taking the rail, and with it every way to reach another tab, down
    /// too. What holds that up is the rail's exact `.frame(width: railWidth)`: unlike a
    /// `minWidth`/`idealWidth` range, an exact frame gives a stack nothing to negotiate
    /// down, so any shortfall lands on a flexible sibling instead (swap it for a flexible
    /// frame and this goes red).
    ///
    /// What this does NOT cover: whether `NavigationSplitView` itself, in a live window,
    /// ever collapses its sidebar column below the window's stated minimum. That is AppKit
    /// window-resize behaviour with no headless equivalent.
    func testRailHoldsItsWidthEvenWhenProposedFarLessThanThat() throws {
        XCTAssertEqual(try renderedRailWidth(proposing: 20), railWidth, accuracy: 0.5)
    }

    func testRailHoldsItsWidthAtAnEvenMoreExtremeSqueeze() throws {
        XCTAssertEqual(try renderedRailWidth(proposing: 1), railWidth, accuracy: 0.5)
    }

    /// Renders `ContentView.rail` the way `body` places it: one side of an `HStack` next to
    /// something that wants the rest of the space, exactly like the split view beside it. A
    /// `rail` rendered alone, with nothing competing for space, would report `railWidth` no
    /// matter how it were sized, so the competing sibling is what makes this measure the
    /// same thing a real narrow window would.
    private func renderedRailWidth(proposing width: CGFloat) throws -> CGFloat {
        let contentView = ContentView(chrome: Chrome())
        let box = WidthBox()
        let probe = HStack(spacing: 0) {
            contentView.rail.background(
                GeometryReader { proxy in
                    Color.clear.onAppear { box.width = proxy.size.width }
                }
            )
            Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        let hosting = NSHostingView(rootView: probe)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        hosting.layoutSubtreeIfNeeded()

        // `onAppear` runs on SwiftUI's own schedule, not synchronously with AppKit layout,
        // so give it a moment to land rather than reading `box` immediately.
        let deadline = Date().addingTimeInterval(1)
        while box.width == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
        }
        return try XCTUnwrap(box.width, "GeometryReader never reported a size")
    }
}

@MainActor
private final class WidthBox {
    var width: CGFloat?
}
