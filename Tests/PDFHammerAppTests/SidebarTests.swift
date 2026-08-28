import XCTest
import SwiftUI
import AppKit
import PDFHammerCore
@testable import PDFHammer

/// The sidebar is one sectioned list now, and the rail it replaced is gone.
///
/// What used to be here were two tests holding up the rail: that all twelve tabs were
/// still reachable, and that the rail kept its exact width when a window was squeezed
/// narrower than both split-view columns. Both described a workaround — a hand-rolled
/// column parked outside the `NavigationSplitView` so macOS could not collapse it — and
/// the workaround is what went. What replaces them is the property that made removing it
/// safe: nothing may be configurable in two places at once.
@MainActor
final class SidebarTests: XCTestCase {

    override class func setUp() {
        // Anything reaching `Library.shared` opens the real store at its default path.
        // Redirecting it first keeps this suite off the library a person keeps their
        // books in. Guarded, since another file in this target may have set its own.
        if getenv("PDFHAMMER_LIBRARY_PATH") == nil {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdfhammer-sidebar-tests-\(UUID().uuidString).sqlite")
            setenv("PDFHAMMER_LIBRARY_PATH", scratch.path, 1)
        }
    }

    /// Every pane a person can reach, named once. A pane dropped from `allCases`, or
    /// renamed without updating this, breaks here first.
    func testSettingsPanesAreAllStillThere() {
        let expected: [SettingsPane] = [
            .general, .files, .naming, .bibtex, .highlighters, .keyboard, .ai, .integrations,
        ]
        XCTAssertEqual(SettingsPane.allCases, expected)
    }

    func testEveryPaneHasItsOwnIconAndTitle() {
        let icons = SettingsPane.allCases.map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count, "two panes share an icon")
        let titles = SettingsPane.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two panes share a title")
        XCTAssertFalse(titles.contains { $0.isEmpty })
    }

    /// The whole point of the move. Every subject that left the sidebar has exactly one
    /// home now, and these are the eight it went to.
    func testEverythingThatLeftTheSidebarHasSomewhereToBe() {
        let titles = Set(SettingsPane.allCases.map(\.title))
        for subject in ["General", "Files & passwords", "Name rules", "BibTeX",
                        "Highlighters", "Keyboard", "AI & spend", "Integrations"] {
            XCTAssertTrue(titles.contains(subject), "\(subject) has nowhere to live")
        }
    }

    /// The rail was forty-six points that sat outside the split view and could never be
    /// collapsed, on top of both columns' own floors. Removing it is what buys the window
    /// its narrower minimum back, so the arithmetic should not quietly grow again.
    func testTheWindowFloorNoLongerPaysForARail() {
        let floor = Metric.sidebarMin + SplitLayout.minWidth(notesShown: false)
        XCTAssertEqual(floor, 220 + SplitLayout.minWidth(notesShown: false))
        XCTAssertLessThan(floor, 1011, "the window got no narrower than it was with the rail")
    }
}
