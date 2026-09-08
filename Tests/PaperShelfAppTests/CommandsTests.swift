import XCTest
import AppKit
import SwiftUI
import PDFKit
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

    func testRenamingIsDiscoverableAndKeepsItsExistingBinding() {
        XCTAssertTrue(ResultsPane.performable.contains(.editName))
        XCTAssertTrue(Command.editName.title.contains("Rename the current file"))
        XCTAssertTrue(Command.editName.searchAliases.contains("filename"))
        XCTAssertTrue(Command.applyOne.searchAliases.contains("rename"))
        XCTAssertEqual(Command.editName.defaultShortcut, Shortcut("e", []))
    }

    func testMenuShortcutsFollowRebindingAndUnbinding() {
        let keymap = Keymap(store: scratchStore())
        keymap.bind(.palette, to: Shortcut("u", [.command, .option]))
        let shortcut = keymap.shortcut(for: .palette)?.keyboardShortcut
        XCTAssertEqual(shortcut?.key, KeyEquivalent("u"))
        XCTAssertEqual(shortcut?.modifiers, [.command, .option])
        XCTAssertEqual(keymap.shortcut(for: .palette)?.display, "⌥⌘U")
        keymap.bind(.palette, to: nil)
        XCTAssertNil(keymap.shortcut(for: .palette)?.keyboardShortcut)
        XCTAssertNil(Shortcut("invalid", []).keyboardShortcut)
    }

    func testConflictsIncludeAlternatesAndDecisionsHeardInTheReader() {
        let keymap = Keymap(store: scratchStore())
        XCTAssertEqual(keymap.conflict(for: Shortcut("c", []), assigning: .editName), .confirm)
        XCTAssertEqual(keymap.conflict(for: Shortcut("1", []), assigning: .trash), .highlight1)
        keymap.bind(.confirm, to: nil)
        XCTAssertNil(keymap.conflict(for: Shortcut("c", []), assigning: .editName))
    }

    func testReaderNoteWinsOverTheNextFileAlternate() {
        let keymap = Keymap(store: scratchStore())
        func command(_ key: String) -> Command? {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: key, charactersIgnoringModifiers: key,
                                        isARepeat: false, keyCode: 0)!
            return ResultsPane.readerCommand(for: event, keymap: keymap)
        }
        XCTAssertEqual(command("n"), .addNote)
        XCTAssertEqual(command("e"), .editName)
        XCTAssertEqual(command("j"), .nextFile)
        XCTAssertEqual(command("d"), .trash)
        keymap.bind(.trash, to: nil)
        XCTAssertNil(command("d"))
    }

    func testDocumentManagementIsAvailableInThePaletteWhileReading() {
        for command in [Command.removeFromLibrary, .trashNow, .revealInFinder, .openExternally, .suggestTags] {
            XCTAssertTrue(ResultsPane.performable.contains(command))
            XCTAssertTrue(command.scope.reachable(from: .reader))
        }
        XCTAssertNil(Command.trashNow.defaultShortcut)
        XCTAssertNil(Command.removeFromLibrary.defaultShortcut)
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

    /// The tab keys against what a keyboard actually sends. `charactersIgnoringModifiers`
    /// accounts for Shift, so ⇧⌘] arrives as `}` and not as the bracket: written the
    /// obvious way round, these two would have shipped as keys that answer to no press
    /// anybody can make, and the settings recorder would have stored a different shortcut
    /// for the same fingers.
    func testTheTabKeysAnswerToWhatTheKeyboardSends() {
        let keymap = Keymap(store: scratchStore())
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: [.command, .shift],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "}", charactersIgnoringModifiers: "}",
                                     isARepeat: false, keyCode: 30)!
        XCTAssertEqual(keymap.command(for: event, in: .reader), .nextTab)
        XCTAssertFalse(Shortcut("]", [.command, .shift]).matches(event),
                       "the bracket is not what that key sends with Shift held")
        // And it is still named after the key it is printed on, the way every other Mac
        // application writes this pair.
        XCTAssertEqual(keymap.shortcut(for: .nextTab)?.display, "⇧⌘]")
        XCTAssertEqual(keymap.shortcut(for: .previousTab)?.display, "⇧⌘[")
    }

    /// Keeping a document has to answer on the shelf, not only over an open one. The
    /// preview tab is the reviewer's selection passing through, so it exists while you are
    /// still browsing; scoped to the reader, ⌘T said nothing at the one moment it is most
    /// wanted, looking at a paper and deciding to hold on to it.
    ///
    /// The other three act on a deck you can only see with the reader open, and a ⌘W that
    /// quietly shut a tab behind the shelf would be worse than one that closes the window,
    /// so they stay where they were put.
    func testKeepingADocumentOpenAnswersWhileBrowsingTheShelf() {
        let keymap = Keymap(store: scratchStore())
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                     modifierFlags: .command,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "t", charactersIgnoringModifiers: "t",
                                     isARepeat: false, keyCode: 17)!
        XCTAssertTrue(Command.openInNewTab.scope.reachable(from: .reviewing),
                      "the preview tab is there before the reader is")
        XCTAssertEqual(keymap.command(for: event, in: .reviewing), .openInNewTab)
        XCTAssertEqual(keymap.command(for: event, in: .reader), .openInNewTab,
                       "and it still has to answer over the page it opened")

        for command in [Command.closeTab, .nextTab, .previousTab] {
            XCTAssertEqual(command.scope, .reader,
                           "\(command.rawValue) wants a deck you can see")
            XCTAssertFalse(command.scope.reachable(from: .reviewing))
        }
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
        XCTAssertTrue(ResultsPane.performable.contains(.readingMode),
                      "reading mode must be reachable from the palette")
        XCTAssertTrue(ResultsPane.performable.contains(.copyCitation),
                      "the current file's BibTeX citation must be reachable from the palette")
        XCTAssertTrue(ResultsPane.performable.contains(.addBookmark))
        XCTAssertTrue(ResultsPane.performable.contains(.showBookmarks))
        XCTAssertTrue(ResultsPane.performable.contains(.removeBookmark))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleSidebar))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleInspector))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleNotes))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleContents))
        XCTAssertTrue(ResultsPane.performable.contains(.closeAllTabs))
        XCTAssertTrue(ResultsPane.performable.contains(.toggleSplit))
        XCTAssertEqual(Command.closeAllTabs.title, "Close all open tabs and return to the library")
        XCTAssertEqual(Command.toggleSplit.defaultShortcut, Shortcut("\\", .command))
        XCTAssertEqual(Command.showBookmarks.title, "Show bookmarks")
        XCTAssertTrue(Command.copyCitation.title.localizedCaseInsensitiveContains("current file"))
        XCTAssertTrue(Command.copyCitation.title.localizedCaseInsensitiveContains("citation"))
        XCTAssertTrue(Command.zenMode.title.localizedCaseInsensitiveContains("presentation mode"))
        XCTAssertTrue(Command.zenMode.title.localizedCaseInsensitiveContains("full screen"))
        XCTAssertEqual(Set(ResultsPane.performable).count, ResultsPane.performable.count,
                       "a command is listed twice")
    }

    func testThePaletteFindsEveryPageControlAndDoesNotTruncateCommands() {
        for fit in PageFit.allCases {
            XCTAssertEqual(CommandPalette.matchingCommands(in: ResultsPane.performable,
                                                          query: fit.label, commandsOnly: false),
                           [fit.command])
        }
        XCTAssertEqual(CommandPalette.matchingCommands(in: ResultsPane.performable,
                                                       query: "", commandsOnly: true),
                       ResultsPane.performable)
        for command in Command.pageActions {
            XCTAssertTrue(ResultsPane.performable.contains(command))
            XCTAssertEqual(command.scope, .reader)
        }
    }

    func testPageCommandsResizeAndNavigateTheAttachedPDF() {
        let document = PDFDocument()
        for _ in 0..<3 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            document.insert(page, at: document.pageCount)
        }
        let view = FitWidthPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf"))
        defer { annotator.detach() }
        let fit = Binding<PageFit>(get: { view.fit }, set: { view.fit = $0; view.layout() })

        XCTAssertTrue(Command.fitPage.performPageAction(on: annotator, fit: fit))
        let pageScale = view.scaleFactor
        XCTAssertTrue(Command.fitWidth.performPageAction(on: annotator, fit: fit))
        XCTAssertGreaterThan(view.scaleFactor, pageScale)
        XCTAssertTrue(Command.actualSize.performPageAction(on: annotator, fit: fit))
        XCTAssertEqual(view.scaleFactor, 1, accuracy: 0.002)
        XCTAssertTrue(Command.lastPage.performPageAction(on: annotator, fit: fit))
        XCTAssertTrue(view.currentPage === document.page(at: 2))
        XCTAssertTrue(Command.previousPage.performPageAction(on: annotator, fit: fit))
        XCTAssertTrue(view.currentPage === document.page(at: 1))
        XCTAssertTrue(Command.firstPage.performPageAction(on: annotator, fit: fit))
        XCTAssertTrue(view.currentPage === document.page(at: 0))
        XCTAssertTrue(Command.nextPage.performPageAction(on: annotator, fit: fit))
        XCTAssertTrue(view.currentPage === document.page(at: 1))
        XCTAssertFalse(Command.fitPage.performPageAction(on: Annotator(), fit: fit))
    }

    func testInspectorToggleIsHandledBeforeASelectionIsRequired() {
        XCTAssertTrue(ResultsPane.alwaysAvailable.contains(.toggleInspector))
        XCTAssertEqual(Keymap.shared.shortcut(for: .toggleInspector),
                       Shortcut("b", [.command, .shift]))
    }

    func testGlobalShortcutsReachEveryCommandScope() {
        let keymap = Keymap(store: scratchStore())
        let palette = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                       modifierFlags: .command,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "k", charactersIgnoringModifiers: "k",
                                       isARepeat: false, keyCode: 40)!
        let pane = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                    modifierFlags: [.command, .shift],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "B", charactersIgnoringModifiers: "b",
                                    isARepeat: false, keyCode: 11)!

        for scope in Command.Scope.allCases {
            XCTAssertEqual(keymap.command(for: palette, in: scope), .palette)
            XCTAssertEqual(keymap.command(for: pane, in: scope), .toggleInspector)
        }
    }

    func testPresentationModeUsesTheNativeFullScreenShortcut() {
        XCTAssertTrue(ResultsPane.alwaysAvailable.contains(.zenMode))
        XCTAssertEqual(Keymap.shared.shortcut(for: .zenMode),
                       Shortcut("f", [.command, .control]))
    }

    /// The library window's keys stay in the library window.
    ///
    /// The monitor that hears them is an app-wide hook running ahead of the responder
    /// chain in every window the process owns. ⌘W pressed in a reader window opened from
    /// Finder closed a tab in the library window and left the reader standing; ⌘W in
    /// Settings did one thing or the other depending on what the library window had open
    /// behind it; ⌘T fired from any window at all. A reader window is exactly where
    /// somebody presses ⌘W.
    func testAKeyPressedInAnotherWindowIsNotThisPanesToAnswer() {
        let library = window()
        let reader = window()
        XCTAssertTrue(ResultsPane.handlesKeys(from: library, in: library))
        XCTAssertFalse(ResultsPane.handlesKeys(from: reader, in: library),
                       "⌘W in a reader window belongs to the reader window")
        XCTAssertFalse(ResultsPane.handlesKeys(from: nil, in: library))
        XCTAssertFalse(ResultsPane.handlesKeys(from: library, in: nil),
                       "a pane not yet in a window answers nothing rather than everything")
    }

    /// A window of its own, never shown: what is being asked is which one a key came from,
    /// and two windows is the whole of what that needs.
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                 styleMask: [.titled], backing: .buffered, defer: true)
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
