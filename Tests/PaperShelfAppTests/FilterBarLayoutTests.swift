import XCTest
import SwiftUI
@testable import PaperShelfCore
@testable import PaperShelf

/// The filter bar is an HStack of `.fixedSize()` controls, which is a shape that does not
/// clip: asked for less room than its children need, it draws them past its own frame and
/// over the divider and the inspector beside it, while reporting a perfectly ordinary
/// size. So the bar folds instead, and these pin down that it folds far enough.
///
/// `NSHostingView` renders the production view, not a reimplementation of it. The chips
/// ahead of these controls are a horizontal `ScrollView` at `layoutPriority(-1)`: they
/// give up their width first and then have none left to give, so what is measured here is
/// what the bar cannot get below.
@MainActor
final class FilterBarLayoutTests: XCTestCase {

    /// Hosts the view in a real (offscreen) window before measuring: SwiftUI text
    /// measurement does not settle on a bare `NSHostingView` that was never attached.
    private func width(of view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2000, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    /// The busiest the bar ever is: a plan running with names still pending, several files
    /// selected, and a search naming a field that does not exist.
    private func busiest(_ fold: BarFold) -> CGFloat {
        width(of: FilterBarControls(
            fold: fold,
            list: true,
            selectionCount: 4,
            shown: "128 of 1204 shown",
            shownIsEmpty: false,
            onlyUndecided: .constant(false),
            autoIdentify: .constant(false),
            aiReady: true,
            hasResults: true,
            pendingCount: 37,
            askAI: {},
            confirmAll: {},
            warning: {
                Label("no field called authr", systemImage: "questionmark.circle")
                    .font(Face.caption)
                    .fixedSize()
            },
            sort: {
                Menu("Date added") { Button("Date added") {} }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }))
    }

    /// The browser column a maximised window leaves on each Mac people read on, at the
    /// width `documentRegionWidth` ships with. The bar is drawn over this column and not
    /// over the whole window.
    private func shelf(screenWidth: CGFloat) -> CGFloat {
        let detail = screenWidth
            - (SplitLayout.startsWithSidebar(screenWidth: screenWidth) ? Metric.sidebarIdeal : 0)
        let inspector = SplitLayout.inspectorWidth(
            preferred: 840, available: detail, contentsShown: true)
        return detail - inspector - SplitLayout.dividerBeforeInspector
    }

    /// What the fix is for. If this ever stops holding, the fold is no longer earning its
    /// keep and these tests are measuring nothing.
    func testTheUnfoldedRowDoesNotFitALaptopShelf() {
        for screen in [1440.0, 1470.0] as [CGFloat] {
            XCTAssertGreaterThan(busiest(.nothing), shelf(screenWidth: screen),
                                 "screen \(screen), shelf \(shelf(screenWidth: screen))")
        }
    }

    /// Every fold has to buy something. A level that draws the same width as the one above
    /// it is a level `ViewThatFits` will never usefully choose.
    func testEachFoldIsNarrowerThanTheOneAboveIt() {
        let full = busiest(.nothing)
        let switches = busiest(.switches)
        let everything = busiest(.everything)
        XCTAssertLessThan(switches, full, "folding the switches saved nothing")
        XCTAssertLessThan(everything, switches, "folding the buttons saved nothing")
    }

    /// The last fold is the one that has to hold. Below `contentFloor` the window itself
    /// will not go, and a bar that still does not fit there has nowhere left to put
    /// anything: it goes back to painting over the pane beside it.
    func testTheLastFoldFitsTheNarrowestPaneTheAppWillDraw() {
        // A chip is about 70 points, and a filter bar that cannot show one filter chip is
        // not saying what is filtering the collection.
        let chip: CGFloat = 70
        let floor = SplitLayout.contentFloor - 2 * Space.roomy
        XCTAssertLessThanOrEqual(busiest(.everything) + chip, floor,
                                 "the fully folded row needs \(busiest(.everything)) of \(floor)")
    }

    /// Whatever the row put away is still reachable, not gone. The fully folded row is
    /// wider than the same bar with nothing to fold, and the difference is the menu: a
    /// fold that simply dropped its controls would come out the same width or narrower.
    func testTheFoldedRowStillDrawsAMenuToReachWhatItPutAway() {
        func bar(list: Bool) -> CGFloat {
            width(of: FilterBarControls(
                fold: .everything, list: list, selectionCount: 1, shown: "4 of 4 shown",
                shownIsEmpty: false, onlyUndecided: .constant(false),
                autoIdentify: .constant(false), aiReady: true, hasResults: true,
                pendingCount: 3, askAI: {}, confirmAll: {},
                warning: { EmptyView() },
                sort: {
                    Menu("Date added") { Button("Date added") {} }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }))
        }
        XCTAssertGreaterThan(bar(list: true), bar(list: false),
                             "the folded row drew nothing to reach the folded controls in")
    }
}
