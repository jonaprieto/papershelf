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

    // MARK: Nothing in the table is decoration

    /// The rule this app is built on, made mechanical: every command does something.
    ///
    /// A command nobody implements is a line in the palette and a row in the settings
    /// table that lies about what the app can do — the same fault as a naming pattern that
    /// renames nothing, or three date switches that change no name. Five commands were
    /// removed rather than left sitting here: moving between regions, jumping to the
    /// sidebar or the status bar, and going back and forward through what you opened. They
    /// can come back when something carries them out.
    func testEveryCommandHasSomethingBehindIt() {
        let performed = Set(ResultsPane.performable)
        let orphans = Set(Command.allCases)
            .subtracting(performed)
            .subtracting(Command.handledByTheMenu)
        XCTAssertTrue(orphans.isEmpty,
                      "no one carries out: \(orphans.map(\.rawValue).sorted().joined(separator: ", "))")
    }

    /// And the other direction: a command claimed by both would be ambiguous about which
    /// one wins, which is how a key starts doing two things depending on focus.
    func testNoCommandIsClaimedTwice() {
        let both = Set(ResultsPane.performable).intersection(Command.handledByTheMenu)
        XCTAssertTrue(both.isEmpty,
                      "claimed twice: \(both.map(\.rawValue).sorted().joined(separator: ", "))")
    }

    /// The palette is built from `performable` minus itself, so every line it offers is a
    /// line that acts. Guards against the list growing an entry the switch does not have.
    func testThePaletteOffersOnlyWhatItCanRun() {
        XCTAssertTrue(ResultsPane.performable.contains(.palette),
                      "the palette has to be reachable by key even though it hides itself")
        XCTAssertEqual(Set(ResultsPane.performable).count, ResultsPane.performable.count,
                       "a command is listed twice")
    }
}
