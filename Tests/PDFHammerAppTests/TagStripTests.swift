import XCTest
import SwiftUI
@testable import PDFHammer

/// The tag surfaces are all fed by one `TagActions`, so what it offers is worth pinning
/// down: a suggestion that is already on the file either does nothing or reads as a way to
/// remove it.
final class TagStripTests: XCTestCase {

    func testSuggestionsLeaveOutWhatTheFileAlreadyCarries() {
        let actions = TagActions(tags: ["reading", "crdt"],
                                 available: ["crdt", "reading", "to read", "types"],
                                 isAvailable: true)

        XCTAssertEqual(actions.suggestions, ["to read", "types"])
    }

    func testNothingIsOfferedWhenTheFileCarriesEverything() {
        let actions = TagActions(tags: ["a", "b"], available: ["a", "b"], isAvailable: true)

        XCTAssertTrue(actions.suggestions.isEmpty)
    }

    /// `.none` is what a view gets when nothing wired tags into it, and it must read as
    /// "no library" rather than "a library with no tags", which would draw a live control
    /// that could not do anything.
    func testTheEmptyValueIsUnavailableRatherThanEmpty() {
        XCTAssertFalse(TagActions.none.isAvailable)
        XCTAssertTrue(TagActions.none.tags.isEmpty)
    }
}

/// `FlowRow` is what wraps the chips. A row that never wraps puts a file's eighth tag off
/// the side of the panel, which is the failure this is here to catch.
@MainActor
final class FlowRowTests: XCTestCase {

    /// The height the layout actually takes at a given width, which is what says how many
    /// lines it used. `fittingSize` cannot answer this: it reports the ideal size, where
    /// nothing is ever short of room and so nothing ever wraps.
    private func rowCount(width: CGFloat, chips: Int) -> Int {
        let box = SizeBox()
        let probe = FlowRow(spacing: 6) {
            ForEach(0..<chips, id: \.self) { _ in
                Color.clear.frame(width: 60, height: 18)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { box.height = proxy.size.height }
        })
        .frame(width: width)

        let hosting = NSHostingView(rootView: probe)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        hosting.layoutSubtreeIfNeeded()
        // Generous on purpose: this waits for SwiftUI's own scheduling, and a second is
        // not always enough on a machine that is busy building something else.
        let deadline = Date().addingTimeInterval(10)
        while box.height == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
        }
        // Each line is an 18pt chip, with 6pt between lines.
        return Int((((box.height ?? 0) + 6) / 24).rounded())
    }

    func testChipsThatFitStayOnOneLine() {
        XCTAssertEqual(rowCount(width: 400, chips: 4), 1)
    }

    func testChipsThatDoNotFitWrap() {
        XCTAssertGreaterThan(rowCount(width: 140, chips: 4), 1)
    }
}

@MainActor
private final class SizeBox {
    var height: CGFloat?
}
