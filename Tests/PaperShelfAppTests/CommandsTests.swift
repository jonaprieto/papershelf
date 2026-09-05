import XCTest
import PaperShelfCore
@testable import PaperShelf

/// The command table is the one place a shortcut is written down now, so these check the
/// properties the rest of the app is about to assume: that every command can be named,
/// that the shipped bindings do not collide, and that a person's changes survive a
/// relaunch — including a command they deliberately unbound.
@MainActor
final class CommandsTests: XCTestCase {

    private func scratchStore() -> UserDefaults {
        let name = "papershelf-keymap-tests-\(UUID().uuidString)"
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

    /// Deciding while a book is open. These are reviewing commands heard in the reader,
    /// so each one has to be a key the reader has not already given a meaning to, or the
    /// same press would highlight a line and trash a file.
    func testTheReaderCanDecideWithoutStealingItsOwnKeys() {
        let readerKeys = Set(Command.allCases
            .filter { $0.scope == .reader }
            .compactMap { Keymap.shared.shortcut(for: $0) })

        for command in ResultsPane.decisionsInTheReader {
            XCTAssertEqual(command.scope, .reviewing,
                           "\(command.rawValue) is not a decision")
            XCTAssertTrue(ResultsPane.performable.contains(command),
                          "\(command.rawValue) cannot be carried out")
            guard let shortcut = Keymap.shared.shortcut(for: command) else { continue }
            XCTAssertFalse(readerKeys.contains(shortcut),
                           "\(command.rawValue) would take a key the reader already uses")
        }
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
        XCTAssertTrue(ResultsPane.performable.contains(.plan),
                      "reviewing renamings must be reachable from the palette")
        XCTAssertTrue(ResultsPane.performable.contains(.apply),
                      "applying renamings must be reachable from the palette")
        XCTAssertTrue(ResultsPane.performable.contains(.zenMode),
                      "full-screen reading must be reachable from the palette")
        XCTAssertTrue(ResultsPane.performable.contains(.copyCitation),
                      "the current file's BibTeX citation must be reachable from the palette")
        XCTAssertTrue(ResultsPane.performable.contains(.addBookmark))
        XCTAssertTrue(ResultsPane.performable.contains(.showBookmarks))
        XCTAssertTrue(ResultsPane.performable.contains(.removeBookmark))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleSidebar))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleInspector))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleNotes))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleContents))
        XCTAssertEqual(Command.showBookmarks.title, "Show bookmarks")
        XCTAssertTrue(Command.copyCitation.title.localizedCaseInsensitiveContains("current file"))
        XCTAssertTrue(Command.copyCitation.title.localizedCaseInsensitiveContains("citation"))
        XCTAssertTrue(Command.zenMode.title.localizedCaseInsensitiveContains("presentation mode"))
        XCTAssertTrue(Command.zenMode.title.localizedCaseInsensitiveContains("full screen"))
        XCTAssertEqual(Set(ResultsPane.performable).count, ResultsPane.performable.count,
                       "a command is listed twice")
    }

    func testInspectorToggleIsHandledBeforeASelectionIsRequired() {
        XCTAssertTrue(ResultsPane.alwaysAvailable.contains(.toggleInspector))
        XCTAssertEqual(Keymap.shared.shortcut(for: .toggleInspector),
                       Shortcut("b", [.command, .shift]))
    }
}

/// The settings window's own search. A pane list of eight is short enough to read and
/// still the wrong thing to make someone read when they know the word they want.
final class SettingsSearchTests: XCTestCase {

    func testAnEmptySearchMatchesEveryPane() {
        for pane in SettingsPane.allCases {
            XCTAssertTrue(pane.matches(""), "\(pane.title)")
            XCTAssertTrue(pane.matches("   "))
        }
    }

    func testAPaneIsFoundByItsOwnName() {
        XCTAssertTrue(SettingsPane.keyboard.matches("keyb"))
        XCTAssertFalse(SettingsPane.keyboard.matches("bibtex"))
    }

    func testGeneralSettingsFindCatalogueOrdering() {
        XCTAssertTrue(SettingsPane.general.matches("sort"))
        XCTAssertTrue(SettingsPane.general.matches("modified date"))
    }

    /// The words a person uses, not the app's. "Dark mode" appears nowhere in the
    /// interface and is exactly what someone will type looking for the theme.
    func testAPaneIsFoundByWhatSomeoneWouldCallIt() {
        XCTAssertTrue(SettingsPane.general.matches("dark mode"))
        XCTAssertTrue(SettingsPane.ai.matches("api key"))
        XCTAssertTrue(SettingsPane.integrations.matches("mcp"))
        XCTAssertTrue(SettingsPane.files.matches("password"))
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertTrue(SettingsPane.bibtex.matches("BibLaTeX"))
    }
}

/// The redesign's second finding: one object with thirty published fields was handed to
/// every row, so a scan tick, a line in the log or a model request about some other file
/// invalidated the whole shelf. What moved off `Runner` stays off it.
@MainActor
final class PublishedStateTests: XCTestCase {

    /// Progress lives on `Activity`. `Runner` does not offer it at all, so the two views
    /// that show it have to read the object that actually changes.
    func testProgressLivesOnItsOwnObject() {
        let runner = Runner()
        runner.activity.done = 7
        runner.activity.total = 12
        XCTAssertEqual(runner.activity.done, 7)
        XCTAssertEqual(runner.activity.total, 12)
    }

    func testTheLogIsWrittenThroughRunnerAndReadFromActivity() {
        let runner = Runner()
        runner.note(.edited, subject: "a.pdf", detail: "renamed")
        XCTAssertEqual(runner.activity.log.count, 1)
        XCTAssertEqual(runner.activity.log.first?.subject, "a.pdf")
    }

    /// The example the artboard gives by name: asking about one file must not touch the
    /// state every row is drawn from.
    func testAskingAboutOneFileTouchesOnlyTheIdentifications() {
        let identifications = Identifications()
        XCTAssertTrue(identifications.begin("a"))
        XCTAssertFalse(identifications.begin("a"), "one request per file at a time")
        XCTAssertTrue(identifications.thinking.contains("a"))
        identifications.end("a")
        XCTAssertTrue(identifications.begin("a"), "and it can be asked again once it is done")
    }

    func testAGuessIsKeptUntilItIsForgotten() {
        let identifications = Identifications()
        identifications.record(BookGuess(title: "Causality", author: "Pearl", year: "2009"),
                               for: "k")
        XCTAssertEqual(identifications.guesses["k"]?.author, "Pearl")
        identifications.forget("k")
        XCTAssertNil(identifications.guesses["k"])
    }
}
