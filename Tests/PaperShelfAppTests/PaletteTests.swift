import XCTest
@testable import PaperShelf

/// The highlighters, which two windows show and one window edits.
///
/// Settings and the reader each used to hold their own `Palette`. Adding a colour changed
/// the settings window's copy and wrote it to preferences, and the reader went on showing
/// the five it had loaded at launch -- so a colour you had just made was in neither the
/// toolbar's picker nor the bar over the page until the app was restarted.
@MainActor
final class PaletteTests: XCTestCase {

    func testEveryHolderSeesTheSamePalette() {
        XCTAssertTrue(Palette.shared === Palette.shared,
                      "there is one palette, and it is the shared one")
    }

    /// The property the two windows read is published, so adding a colour redraws both
    /// rather than only the window that added it.
    func testAddingAColourIsVisibleToEveryHolder() {
        let palette = Palette.shared
        let before = palette.styles.count
        defer {
            // Put back whatever this machine had, so a test run is not an edit to the
            // reader's own highlighters.
            while palette.styles.count > before, let last = palette.styles.last {
                palette.remove(last)
            }
        }

        palette.add()
        XCTAssertEqual(palette.styles.count, before + 1)
        XCTAssertEqual(Palette.shared.styles.count, before + 1,
                       "another holder is looking at the same list")
    }

    /// The last one cannot go: with no colours there is no way to highlight, which is not
    /// a state anybody chose.
    func testTheLastColourStays() {
        let palette = Palette.shared
        let kept = palette.styles
        defer { palette.resetToDefaults(); _ = kept }

        while palette.styles.count > 1, let last = palette.styles.last {
            palette.remove(last)
        }
        XCTAssertEqual(palette.styles.count, 1)
        palette.remove(palette.styles[0])
        XCTAssertEqual(palette.styles.count, 1, "the last highlighter cannot be removed")
    }
}
