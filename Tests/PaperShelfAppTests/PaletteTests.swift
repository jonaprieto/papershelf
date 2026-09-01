import XCTest
import SwiftUI
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

    /// The property the two windows read is tracked, so adding a colour redraws both
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

    func testPaperMeaningOverridesTheLibraryDefaultAndCanInheritAgain() {
        let palette = Palette.shared
        let style = palette.styles[0]
        let scope = HighlightMeaningScope.document(id: "doc-\(UUID().uuidString)",
                                                   name: "meaning.pdf")
        defer { palette.resetMeanings(in: scope) }

        let libraryMeaning = palette.meaning(for: style)
        XCTAssertEqual(palette.meaning(for: style, scope: scope), libraryMeaning)
        XCTAssertEqual(palette.meaningOverride(for: style, scope: scope), "")

        palette.setMeaning("Delete", on: style, scope: scope)
        XCTAssertEqual(palette.meaning(for: style, scope: scope), "Delete")
        XCTAssertEqual(palette.meaningOverride(for: style, scope: scope), "Delete")
        XCTAssertEqual(palette.meaning(for: style), libraryMeaning)

        palette.setMeaning("", on: style, scope: scope)
        XCTAssertEqual(palette.meaning(for: style, scope: scope), libraryMeaning)
        XCTAssertEqual(palette.meaningOverride(for: style, scope: scope), "")
    }

    func testProjectMeaningIsSeparateFromPaperMeaning() {
        let palette = Palette.shared
        let style = palette.styles[0]
        let paperID = "paper-\(UUID().uuidString)"
        let paper = HighlightMeaningScope.document(id: paperID,
                                                   name: "paper.pdf")
        let project = HighlightMeaningScope.project(id: Int64.random(in: 1...Int64.max),
                                                    name: "Editing")
        defer {
            palette.resetMeanings(in: paper)
            palette.resetMeanings(in: project)
        }

        palette.setMeaning("Rewrite", on: style, scope: project)
        XCTAssertEqual(palette.meaning(for: style, scope: project), "Rewrite")
        XCTAssertEqual(palette.meaning(for: style, scope: paper), palette.meaning(for: style))

        palette.setMeaning("Delete", on: style, scope: paper)
        XCTAssertEqual(palette.meaning(for: style,
                                       scopes: [paper, project, .library]), "Delete")
        let renamedPaper = HighlightMeaningScope.document(id: paperID, name: "renamed.pdf")
        XCTAssertEqual(palette.meaning(for: style, scope: renamedPaper), "Delete",
                       "a filename change keeps the paper override")
    }

    func testFolderOverridesColourAndMeaningForItsDocuments() {
        let palette = Palette.shared
        let style = palette.styles[0]
        let folder = HighlightMeaningScope.folder(path: "/tmp/papers-\(UUID().uuidString)",
                                                   name: "papers")
        defer { palette.resetMeanings(in: folder) }

        palette.setColour(Color(nsColor: .systemBlue), on: style, scope: folder)
        palette.setMeaning("Rewrite", on: style, scope: folder)

        let scoped = try! XCTUnwrap(
            palette.styles(for: [.document(id: "doc", name: "paper.pdf"), folder, .library])
                .first { $0.id == style.id })
        XCTAssertEqual(scoped.meaning, "Rewrite")
        XCTAssertLessThan(scoped.distance(to: .systemBlue), 0.0001)
    }
}
