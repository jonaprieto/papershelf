import SwiftUI
import AppKit

/// Every command the app can perform, named once.
///
/// The keys were spread across three places that had no idea about each other: a hand-written
/// `NSEvent` monitor, a `Commands` block in the scene, and a read-only cheat sheet that
/// listed them as strings and could drift from either. Naming them here makes the sheet
/// generated rather than typed, lets a person rebind one, and gives the palette something
/// to list — including the commands that have no shortcut at all.
enum Command: String, CaseIterable, Identifiable, Codable, Sendable {
    // Getting around
        case palette
    case focusSidebar, focusContents, focusDocument, focusInspector, focusStatus
    case nextRegion, previousRegion
    case back, forward
    case focusSearch, toggleSidebar, toggleInspector

    // Views
    case viewList, viewCatalogue, viewBibliography, viewDuplicates
    case readingMode, zenMode, toggleNotes, toggleContents

    // Deciding
    case confirm, editName, askAI, copyCitation, applyOne
    case skip, skipFolder, moveTo, trash, reopen
    case nextFile, previousFile, confirmAllPending, undo

    // Reading
    case highlight1, highlight2, highlight3, highlight4, highlight5
    case addNote, addBookmark, showBookmarks, removeBookmark
    case nextMark, previousMark, openExternally

    // Library
    case plan, apply, refresh, findDuplicates, indexText, revealInFinder, newTag, shortcuts

    var id: String { rawValue }

    /// Where a command is listening. Two commands may share a shortcut only if their
    /// scopes cannot both be active, which is what makes `S` for skip and `S` for
    /// something else in the reader a question worth asking rather than a silent
    /// last-one-wins.
    enum Scope: String, CaseIterable, Codable, Sendable {
        case anywhere, library, reviewing, reader

        var label: String {
            switch self {
            case .anywhere: return "Anywhere"
            case .library: return "Library"
            case .reviewing: return "Reviewing"
            case .reader: return "Reader"
            }
        }

        /// Whether a command in this scope can fire while `active` is what the window is
        /// doing. `anywhere` always can, and so does `library` — those are the ⌘ keys that
        /// should keep working wherever you happen to be standing. The rest only answer in
        /// their own place.
        func reachable(from active: Scope) -> Bool {
            self == .anywhere || self == .library || self == active
        }
    }

    enum Group: String, CaseIterable, Codable, Sendable {
        case gettingAround, views, deciding, reading, library

        var label: String {
            switch self {
            case .gettingAround: return "Getting around"
            case .views: return "Views"
            case .deciding: return "Deciding"
            case .reading: return "Reading"
            case .library: return "Library"
            }
        }
    }

    var group: Group {
        switch self {
        case .palette, .focusSidebar, .focusContents, .focusDocument, .focusInspector,
             .focusStatus, .nextRegion, .previousRegion,
             .back, .forward,
             .focusSearch, .toggleSidebar, .toggleInspector:
            return .gettingAround
        case .viewList, .viewCatalogue, .viewBibliography, .viewDuplicates,
             .readingMode, .zenMode, .toggleNotes, .toggleContents:
            return .views
        case .confirm, .editName, .askAI, .copyCitation, .applyOne, .skip, .skipFolder,
             .moveTo, .trash, .reopen, .nextFile, .previousFile, .confirmAllPending, .undo:
            return .deciding
        case .highlight1, .highlight2, .highlight3, .highlight4, .highlight5,
             .addNote, .addBookmark, .showBookmarks, .removeBookmark,
             .nextMark, .previousMark, .openExternally:
            return .reading
        case .plan, .apply, .refresh, .findDuplicates, .indexText, .revealInFinder, .newTag,
             .shortcuts:
            return .library
        }
    }

    var scope: Scope {
        switch self {
        case .focusContents, .toggleContents, .toggleNotes,
             .highlight1, .highlight2, .highlight3, .highlight4, .highlight5,
             .addNote, .addBookmark, .showBookmarks, .removeBookmark,
             .nextMark, .previousMark:
            return .reader
        case .confirm, .editName, .askAI, .copyCitation, .applyOne, .skip, .skipFolder,
             .moveTo, .trash, .reopen, .nextFile, .previousFile, .confirmAllPending:
            return .reviewing
        case .viewList, .viewCatalogue, .viewBibliography, .viewDuplicates,
             .plan, .apply, .refresh, .findDuplicates, .indexText, .revealInFinder, .newTag,
             .openExternally:
            return .library
        default:
            return .anywhere
        }
    }

    /// What the command is called, everywhere it is named: the palette, the settings
    /// table, the menu and the shortcut sheet all read this rather than repeating it.
    var title: String {
        switch self {
        case .palette: return "Open the command palette"
        case .focusSidebar: return "Jump to the sidebar"
        case .focusContents: return "Jump to the contents"
        case .focusDocument: return "Jump to the document"
        case .focusInspector: return "Jump to the inspector"
        case .focusStatus: return "Jump to the status bar"
        case .nextRegion: return "Move to the next region"
        case .previousRegion: return "Move to the previous region"
        case .back: return "Go back to the previous place"
        case .forward: return "Go forward to the next place"
        case .focusSearch: return "Focus the search field"
        case .toggleSidebar: return "Show or hide the sidebar"
        case .toggleInspector: return "Show or hide the inspector"
        case .viewList: return "List"
        case .viewCatalogue: return "Shelf"
        case .viewBibliography: return "BibTeX"
        case .viewDuplicates: return "Duplicates"
        case .readingMode: return "Reading mode"
        case .zenMode: return "Zen mode (full screen)"
        case .toggleNotes: return "Show or hide the notes"
        case .toggleContents: return "Show or hide the contents"
        case .confirm: return "Confirm the name and go to the next file"
        case .editName: return "Edit the name"
        case .askAI: return "Ask the model for a name"
        case .copyCitation: return "Copy the current file's BibTeX citation"
        case .applyOne: return "Apply this one file now"
        case .skip: return "Leave this file alone"
        case .skipFolder: return "Leave the rest of this folder alone"
        case .moveTo: return "Move to another folder"
        case .trash: return "Move to the Trash on apply"
        case .reopen: return "Reopen a decided file"
        case .nextFile: return "Next file"
        case .previousFile: return "Previous file"
        case .confirmAllPending: return "Confirm everything still pending"
        case .undo: return "Undo the last decision"
        case .highlight1: return "Highlight with colour 1"
        case .highlight2: return "Highlight with colour 2"
        case .highlight3: return "Highlight with colour 3"
        case .highlight4: return "Highlight with colour 4"
        case .highlight5: return "Highlight with colour 5"
        case .addNote: return "Add a note to the selection"
        case .addBookmark: return "Add a bookmark at the current page"
        case .showBookmarks: return "Show bookmarks"
        case .removeBookmark: return "Remove the bookmark at the current page"
        case .nextMark: return "Next highlight"
        case .previousMark: return "Previous highlight"
        case .openExternally: return "Open in the default PDF viewer"
        case .plan: return "Plan renames"
        case .apply: return "Apply the reviewed plan"
        case .refresh: return "Read the sources again"
        case .findDuplicates: return "Find duplicates"
        case .indexText: return "Index text for search"
        case .revealInFinder: return "Reveal in Finder"
        case .newTag: return "New tag…"
        case .shortcuts: return "Every shortcut"
        }
    }

    /// What the app ships with. A command may have none: it is still reachable from the
    /// palette, which is the point of naming every one of them here.
    var defaultShortcut: Shortcut? {
        switch self {
        case .palette: return Shortcut("k", .command)
        case .focusSidebar: return Shortcut("1", .control)
        case .focusContents: return Shortcut("2", .control)
        case .focusDocument: return Shortcut("3", .control)
        case .focusInspector: return Shortcut("4", .control)
        case .focusStatus: return Shortcut("5", .control)
        case .nextRegion: return Shortcut("\t", .control)
        case .previousRegion: return Shortcut("\t", [.control, .shift])
        case .back: return Shortcut("[", .command)
        case .forward: return Shortcut("]", .command)
        case .focusSearch: return Shortcut("/", [])
        case .toggleSidebar: return Shortcut("b", .command)
        case .toggleInspector: return Shortcut("b", [.command, .shift])
        case .viewList: return Shortcut("1", .command)
        case .viewCatalogue: return Shortcut("2", .command)
        case .viewBibliography: return Shortcut("3", .command)
        case .viewDuplicates: return Shortcut("4", .command)
        case .readingMode: return Shortcut("r", [.command, .shift])
        // Full screen is deliberately palette-only: a shortcut would compete with the
        // native window command and the toolbar's reading controls.
        case .zenMode: return nil
        case .toggleNotes: return Shortcut("n", [.command, .shift])
        case .toggleContents: return Shortcut("t", [.command, .shift])
        case .confirm: return Shortcut("\r", [])
        case .editName: return Shortcut("e", [])
        case .askAI: return Shortcut("g", [])
        case .copyCitation: return Shortcut("b", [])
        case .applyOne: return Shortcut("a", [])
        case .skip: return Shortcut("s", [])
        case .skipFolder: return Shortcut("f", [])
        case .moveTo: return Shortcut("m", [])
        case .trash: return Shortcut("d", [])
        case .reopen: return Shortcut("r", [])
        case .nextFile: return Shortcut("j", [])
        case .previousFile: return Shortcut("k", [])
        case .confirmAllPending: return Shortcut("\r", [.command, .shift])
        case .undo: return Shortcut("z", .command)
        case .highlight1: return Shortcut("1", [])
        case .highlight2: return Shortcut("2", [])
        case .highlight3: return Shortcut("3", [])
        case .highlight4: return Shortcut("4", [])
        case .highlight5: return Shortcut("5", [])
        case .addNote: return Shortcut("n", [])
        case .addBookmark, .showBookmarks, .removeBookmark: return nil
        case .nextMark: return Shortcut("\u{F701}", .option)
        case .previousMark: return Shortcut("\u{F700}", .option)
        case .openExternally: return Shortcut("o", [])
        case .plan: return Shortcut("p", .command)
        case .apply: return Shortcut("\r", .command)
        case .findDuplicates: return Shortcut("d", .command)
        // No default shortcut: this one reads every file on the shelf, so it is asked for
        // by name rather than fired by a key someone can hit while reaching for another.
        case .indexText: return nil
        // ⌘R reads the disk again, which is what ⌘R means in a browser and in every
        // file window. Reveal keeps the letter and takes a modifier.
        case .refresh: return Shortcut("r", .command)
        case .revealInFinder: return Shortcut("r", [.command, .option])
        case .newTag: return nil
        case .shortcuts: return Shortcut("?", [])
        }
    }

    /// The second key some commands have always answered to. Not rebindable and not shown
    /// as the shortcut: `C` confirms because a hand resting on the left of the keyboard
    /// should not have to reach for Return, and `N`/`P` move because some people's do.
    var alternates: [Shortcut] {
        switch self {
        case .confirm: return [Shortcut("c", [])]
        case .nextFile: return [Shortcut("n", []), Shortcut("\u{F701}", [])]
        case .previousFile: return [Shortcut("p", []), Shortcut("\u{F700}", [])]
        default: return []
        }
    }
}

// MARK: - Shortcut

/// One key with its modifiers, in the form the event monitor compares and a person reads.
struct Shortcut: Codable, Equatable, Hashable, Sendable {
    /// The character the key produces with the modifiers taken off, lowercased. Arrow keys
    /// and Return arrive as their own scalars, which is why this is a string.
    var key: String
    var modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)

        /// In the order the platform writes them, so ⌃⌥⇧⌘ never comes out shuffled.
        var display: String {
            var out = ""
            if contains(.control) { out += "⌃" }
            if contains(.option) { out += "⌥" }
            if contains(.shift) { out += "⇧" }
            if contains(.command) { out += "⌘" }
            return out
        }

        init(_ flags: NSEvent.ModifierFlags) {
            var value: Modifiers = []
            if flags.contains(.command) { value.insert(.command) }
            if flags.contains(.shift) { value.insert(.shift) }
            if flags.contains(.option) { value.insert(.option) }
            if flags.contains(.control) { value.insert(.control) }
            self = value
        }
    }

    /// How the key reads on a cap: ⏎ rather than a carriage return nobody can see.
    var display: String {
        let name: String
        switch key {
        case "\r", "\n": name = "↩"
        case "\t": name = "⇥"
        case " ": name = "Space"
        case "\u{1B}": name = "⎋"
        case "\u{7F}", "\u{8}": name = "⌫"
        case "\u{F700}": name = "↑"
        case "\u{F701}": name = "↓"
        case "\u{F702}": name = "←"
        case "\u{F703}": name = "→"
        default: name = key.uppercased()
        }
        return modifiers.display + name
    }

    /// Whether a key press is this shortcut. Compares the characters with the modifiers
    /// taken off, so ⇧/ is still `?` and ⌥↓ is still the down arrow.
    func matches(_ event: NSEvent) -> Bool {
        guard let typed = event.charactersIgnoringModifiers?.lowercased(), typed == key else {
            return false
        }
        var pressed = Modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        var wanted = modifiers
        // Shift is how `?` is produced from `/` on most layouts, so it is part of the
        // character rather than part of the binding.
        if key == "?" {
            pressed.remove(.shift)
            wanted.remove(.shift)
        }
        return pressed == wanted
    }
}

// MARK: - Keymap

/// What every command is bound to, and the one place that answers "what does this key do
/// here". Only the changes a person makes are stored, so the defaults above can grow
/// without stranding anyone on an old copy of them.
@MainActor
@Observable
final class Keymap {
    /// One map for the whole app. The settings window and the window that listens for the
    /// keys are different scenes; two instances would drift until the next launch.
    static let shared = Keymap()

    private(set) var overrides: [Command: Shortcut?] = [:]

    private let defaultsKey = "keymap"
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        load()
    }

    /// What this command answers to now.
    func shortcut(for command: Command) -> Shortcut? {
        if let override = overrides[command] { return override }
        return command.defaultShortcut
    }

    func isCustomised(_ command: Command) -> Bool { overrides[command] != nil }

    var hasCustomisations: Bool { !overrides.isEmpty }

    /// The command a key press means, given what the window is doing. Nil when the key is
    /// not bound in a scope that can currently hear it.
    func command(for event: NSEvent, in active: Command.Scope) -> Command? {
        for command in Command.allCases where command.scope.reachable(from: active) {
            if let shortcut = shortcut(for: command), shortcut.matches(event) { return command }
            if overrides[command] == nil,
               command.alternates.contains(where: { $0.matches(event) }) { return command }
        }
        return nil
    }

    /// The command already using this shortcut somewhere it could also be heard, if any.
    /// Two commands in scopes that cannot both be active are not a conflict.
    func conflict(for shortcut: Shortcut, assigning command: Command) -> Command? {
        Command.allCases.first { other in
            guard other != command else { return false }
            guard shortcut == self.shortcut(for: other) else { return false }
            return other.scope.overlaps(command.scope)
        }
    }

    func bind(_ command: Command, to shortcut: Shortcut?) {
        overrides[command] = .some(shortcut)
        save()
    }

    func reset(_ command: Command) {
        overrides.removeValue(forKey: command)
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    // MARK: Storage

    /// Stored as command -> shortcut, with a missing shortcut written as null so
    /// "deliberately unbound" survives a relaunch and does not silently come back.
    private func load() {
        guard let data = store.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: Shortcut?].self, from: data)
        else { return }
        overrides = stored.reduce(into: [:]) { out, pair in
            guard let command = Command(rawValue: pair.key) else { return }
            out[command] = pair.value
        }
    }

    private func save() {
        let stored = overrides.reduce(into: [String: Shortcut?]()) { out, pair in
            out[pair.key.rawValue] = pair.value
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        store.set(data, forKey: defaultsKey)
    }
}

extension Command {
    /// Commands the app's menu bar and toolbar carry out, rather than the results pane.
    ///
    /// Listed so that a test can hold the whole table to the rule this app is built on:
    /// every command does something. A command nobody implements is a line in the palette
    /// and a row in the settings table that lies about what the app can do, and there is
    /// no version of that which is acceptable.
    static let handledByTheMenu: Set<Command> = [
        .undo, .readingMode,
        .toggleSidebar, .toggleInspector, .toggleNotes, .toggleContents,
    ]
}

extension Command.Scope {
    /// Whether two scopes can be listening at the same moment, which is what makes a
    /// shared key a conflict rather than a coincidence.
    ///
    /// Only one pair is genuinely exclusive: deciding a name and reading the page are the
    /// same pane in two states you are never in at once, which is what lets `S` skip a
    /// file and `1` highlight a passage without either having to reach for a modifier.
    func overlaps(_ other: Command.Scope) -> Bool {
        !(self == .reviewing && other == .reader) && !(self == .reader && other == .reviewing)
    }
}
