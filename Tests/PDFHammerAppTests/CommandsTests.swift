import XCTest
@testable import PDFHammer

/// The command table is the one place a shortcut is written down now, so these check the
/// properties the rest of the app is about to assume: that every command can be named,
/// that the shipped bindings do not collide, and that a person's changes survive a
/// relaunch — including a command they deliberately unbound.
@MainActor
final class CommandsTests: XCTestCase {

    private func scratchStore() -> UserDefaults {
        let name = "pdfhammer-keymap-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return store
    }

    func testEveryCommandIsNamed() {
        for command in Command.allCases {
            XCTAssertFalse(command.title.isEmpty, "\(command.rawValue) has no title")
        }
    }

    /// The point of the scope column. Two commands may share a key only when they cannot
    /// both be listening, which is the rule the settings pane enforces when rebinding.
    func testShippedBindingsDoNotCollide() {
        let keymap = Keymap(store: scratchStore())
        for command in Command.allCases {
            guard let shortcut = command.defaultShortcut else { continue }
            if let clash = keymap.conflict(for: shortcut, assigning: command) {
                XCTFail("\(command.rawValue) and \(clash.rawValue) both answer to \(shortcut.display)")
            }
        }
    }

    /// `S` skips while reviewing and `1` highlights while reading; neither is a conflict,
    /// because the two scopes are never active at the same moment.
    func testScopesThatCannotOverlapAreNotAConflict() {
        XCTAssertFalse(Command.Scope.reviewing.overlaps(.reader))
        XCTAssertTrue(Command.Scope.anywhere.overlaps(.reader))
        XCTAssertTrue(Command.Scope.reader.overlaps(.reader))
    }

    func testModifiersReadInPlatformOrder() {
        let shortcut = Shortcut("t", [.command, .shift, .option, .control])
        XCTAssertEqual(shortcut.display, "⌃⌥⇧⌘T")
        XCTAssertEqual(Shortcut("\r", [.command, .shift]).display, "⇧⌘↩")
        XCTAssertEqual(Shortcut("\u{F700}", .option).display, "⌥↑")
    }

    func testRebindingSurvivesARelaunch() {
        let store = scratchStore()
        let keymap = Keymap(store: store)
        keymap.bind(.newTag, to: Shortcut("t", [.command, .control]))

        let reopened = Keymap(store: store)
        XCTAssertEqual(reopened.shortcut(for: .newTag), Shortcut("t", [.command, .control]))
        XCTAssertTrue(reopened.isCustomised(.newTag))
    }

    /// A command taken off the keyboard has to stay off it. Storing only the changes means
    /// "unbound" has to be written down as its own answer rather than as an absence.
    func testUnbindingSurvivesARelaunch() {
        let store = scratchStore()
        let keymap = Keymap(store: store)
        keymap.bind(.trash, to: nil)

        let reopened = Keymap(store: store)
        XCTAssertNil(reopened.shortcut(for: .trash))
        XCTAssertNotNil(Command.trash.defaultShortcut, "the default is what it is being held back from")
    }

    func testResettingRestoresTheShippedBinding() {
        let keymap = Keymap(store: scratchStore())
        keymap.bind(.plan, to: Shortcut("y", .command))
        XCTAssertEqual(keymap.shortcut(for: .plan), Shortcut("y", .command))

        keymap.reset(.plan)
        XCTAssertEqual(keymap.shortcut(for: .plan), Command.plan.defaultShortcut)
        XCTAssertFalse(keymap.isCustomised(.plan))
    }

    /// The collision the settings pane is drawn showing: a new tag command reaching for
    /// the keys that already show and hide the contents.
    func testConflictIsFoundAcrossOverlappingScopes() {
        let keymap = Keymap(store: scratchStore())
        let contents = keymap.shortcut(for: .toggleContents)
        XCTAssertEqual(contents, Shortcut("t", [.command, .shift]))
        XCTAssertEqual(keymap.conflict(for: contents!, assigning: .newTag), .toggleContents)
    }

    func testResetAllClearsEverything() {
        let keymap = Keymap(store: scratchStore())
        keymap.bind(.plan, to: Shortcut("y", .command))
        keymap.bind(.trash, to: nil)
        XCTAssertTrue(keymap.hasCustomisations)

        keymap.resetAll()
        XCTAssertFalse(keymap.hasCustomisations)
        XCTAssertEqual(keymap.shortcut(for: .trash), Command.trash.defaultShortcut)
    }
}
