import SwiftUI
import AppKit
import PaperShelfCore

/// Somewhere to go, reachable by name: a library list, a folder, a project, a tag.
struct PalettePlace: Identifiable {
    enum Kind: String {
        case list, folder, project, tag, document

        var icon: String {
            switch self {
            case .list: return "books.vertical"
            case .folder: return "folder"
            case .project: return "bubble.left.and.bubble.right"
            case .tag: return "tag"
            case .document: return "doc.text.magnifyingglass"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let kind: Kind
    let go: () -> Void
}

/// A match inside the document on screen: the passage, and the page to turn to.
struct PageHit: Identifiable {
    let id: String
    let page: Int
    let line: String
    let go: () -> Void
}

/// Everything the palette can reach that is not a command or a file on the shelf.
///
/// Closures rather than values, because each of these is answered by a different owner:
/// the shelf knows its folders, the library knows its projects and its text, and the
/// reader knows the document open in front of you.
struct PaletteSources {
    var places: [PalettePlace] = []
    /// Full-text hits from the library, for a query that is not a prefix.
    var inTheText: (String) async -> [TextHit] = { _ in [] }
    /// Documents anywhere in the library whose title, author or PDF info mentions the
    /// query -- including the ones the shelf in front of you is not showing, and the ones
    /// whose text has never been extracted.
    var inTheLibrary: (String) async -> [PalettePlace] = { _ in [] }
    /// Matches inside the document on screen, for `/`.
    var inThisDocument: (String) -> [PageHit] = { _ in [] }
    /// Turns the document on screen to a page, for `:`.
    var goToPage: ((Int) -> Void)?
    var help: () -> Void = {}
}

/// One field that reaches everything: where you can go, the files in front of you, the
/// text inside them, and every command the app has -- including the ones with no shortcut.
///
/// The point is not speed for people who already know the keys -- they have the keys. It
/// is that a command with no binding stops being unreachable without a mouse, which is
/// what made naming all of them in one table worth doing.
struct CommandPalette: View {
    /// Commands the presenting surface can actually carry out — see
    /// `ResultsPane.performable`. Passed in rather than read from `Command.allCases`, so
    /// the palette never offers a line that would do nothing.
    let commands: [Command]
    let documents: [Item]
    let run: (Command) -> Void
    let open: (Item) -> Void
    var sources = PaletteSources()

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @State private var textHits: [TextHit] = []
    @State private var libraryHits: [PalettePlace] = []
    @FocusState private var fieldFocused: Bool

    private enum Entry: Identifiable {
        case starter(Mode)
        case setting(PaletteSetting)
        case place(PalettePlace)
        case command(Command)
        case document(Item)
        case text(TextHit)
        case page(PageHit)

        var id: String {
            switch self {
            case .starter(let mode): return "s:" + String(mode.rawValue)
            case .setting(let setting): return "g:" + setting.id
            case .place(let place): return "p:" + place.id
            case .command(let c): return "c:" + c.rawValue
            case .document(let item): return "d:" + item.key
            case .text(let hit): return "t:" + hit.id
            case .page(let hit): return "g:" + hit.id
            }
        }
    }

    /// What a leading character narrows the field to. Anything else searches everything.
    private enum Mode: Character {
        case commands = ">"
        case tags = "#"
        case projects = "@"
        case inDocument = "/"
        case page = ":"
        case help = "?"
    }

    private var mode: Mode? { query.first.flatMap(Mode.init) }

    /// The prefixes, spelled out. They used to live only in one line of grey text under
    /// the results, which is the sort of legend nobody reads: an empty field now offers
    /// them as rows, and picking one types the character for you.
    private static let starters: [(mode: Mode, title: String, detail: String)] = [
        (.commands, "Commands", "every one, key or no key"),
        (.tags, "Tags", "documents filed under a tag"),
        (.projects, "Projects", "a project and its papers"),
        (.inDocument, "In this document", "find a passage, turn to it"),
        (.page, "Page number", "turn to a page"),
        (.help, "All shortcuts", "the whole table, in a window"),
    ]

    /// An empty field has nothing to match, so it shows the way in instead.
    private var showsStarters: Bool { mode == nil && needle.isEmpty }

    /// What has been typed after the prefix, exactly as typed. Completion works off this
    /// rather than `needle`, which is trimmed and lowercased and so cannot say where the
    /// text you typed ends and the suggestion begins.
    private var typed: String {
        mode == nil ? query : String(query.dropFirst())
    }

    private func completableTitle(of entry: Entry) -> String? {
        switch entry {
        case .command(let command): return command.title
        case .place(let place): return place.title
        case .document(let item): return item.currentFilename
        case .setting(let setting): return setting.title
        case .starter, .page, .text: return nil
        }
    }

    /// The full name of the highlighted row, when what you have typed is the start of it.
    /// Nil for a row whose text is not something you could have typed your way to -- a
    /// passage of a document, a page number -- and nil while the field ends in a space,
    /// where a suggestion would be drawn a space away from the word it completes.
    private var completion: String? {
        guard !typed.isEmpty, typed.trimmingCharacters(in: .whitespaces) == typed,
              entries.indices.contains(index),
              let title = completableTitle(of: entries[index]),
              title.count > typed.count,
              title.lowercased().hasPrefix(typed.lowercased()) else { return nil }
        return title
    }

    /// The part of the suggestion you have not typed yet, drawn behind the field.
    private var ghost: String {
        completion.map { String($0.dropFirst(typed.count)) } ?? ""
    }

    private func acceptCompletion() -> KeyPress.Result {
        guard let completion else { return .ignored }
        query = (mode.map { String($0.rawValue) } ?? "") + completion
        return .handled
    }

    private var needle: String {
        (mode == nil ? query : String(query.dropFirst()))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private func matches(_ text: String) -> Bool {
        needle.isEmpty || text.lowercased().contains(needle)
    }

    /// The preferences, findable by name and flipped where they stand. A setting nobody
    /// can remember the pane of is a setting nobody changes.
    private var matchingSettings: [PaletteSetting] {
        guard mode == nil || mode == .commands, !needle.isEmpty else { return [] }
        return PaletteSettings.all().filter { matches($0.title) }.prefix(5).map { $0 }
    }

    private var matchingCommands: [Command] {
        guard mode == nil || mode == .commands else { return [] }
        guard !needle.isEmpty || mode == .commands else { return [] }
        return commands.filter { matches($0.title) }.prefix(8).map { $0 }
    }

    private var matchingPlaces: [PalettePlace] {
        let kinds: Set<PalettePlace.Kind>
        switch mode {
        case .none: kinds = [.list, .folder, .project, .tag]
        case .tags: kinds = [.tag]
        case .projects: kinds = [.project]
        default: return []
        }
        guard !needle.isEmpty || mode != nil else { return [] }
        return sources.places.filter { kinds.contains($0.kind) && matches($0.title) }
            .prefix(6).map { $0 }
    }

    private var matchingDocuments: [Item] {
        guard mode == nil, !needle.isEmpty else { return [] }
        return documents.filter {
            matches($0.currentFilename) || matches($0.source.lastPathComponent)
        }
        .prefix(6).map { $0 }
    }

    private var matchingPages: [PageHit] {
        switch mode {
        case .inDocument:
            guard !needle.isEmpty else { return [] }
            return sources.inThisDocument(needle)
        case .page:
            guard let number = Int(needle), let go = sources.goToPage else { return [] }
            return [PageHit(id: "page-\(number)", page: number,
                            line: "Turn to page \(number)") { go(number) }]
        default:
            return []
        }
    }

    /// Library matches, minus anything the shelf is already offering under Documents.
    /// A place's id is "doc:" and the file's path, which is `Item.key`.
    private var elsewhereInLibrary: [PalettePlace] {
        let shown = Set(matchingDocuments.map(\.key))
        return libraryHits.filter { !shown.contains(String($0.id.dropFirst(4))) }
    }

    private var entries: [Entry] {
        if showsStarters { return Self.starters.map { Entry.starter($0.mode) } }
        return matchingPlaces.map(Entry.place)
            + matchingPages.map(Entry.page)
            + matchingDocuments.map(Entry.document)
            + elsewhereInLibrary.map(Entry.place)
            + textHits.map(Entry.text)
            + matchingCommands.map(Entry.command)
            + matchingSettings.map(Entry.setting)
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 640)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { index = 0 }
        .task(id: needle) { await searchTheLibrary() }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    /// The library, asked after a pause: a keystroke is not a search. Metadata and text
    /// are two queries because they fail independently -- a library nobody has indexed
    /// still answers on title and author, which is the half that works on day one.
    private func searchTheLibrary() async {
        guard mode == nil, needle.count >= 2 else {
            textHits = []
            libraryHits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        let query = needle
        libraryHits = await sources.inTheLibrary(query)
        guard !Task.isCancelled, query == needle else { return }
        textHits = await sources.inTheText(query)
    }

    private var field: some View {
        HStack(spacing: Space.step) {
            Image(systemName: mode == nil ? "magnifyingglass" : "chevron.right")
                .foregroundStyle(mode == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            ZStack(alignment: .leading) {
                // The rest of the highlighted row's name, drawn behind the field. The
                // typed half is clear rather than absent so the two halves lay out as one
                // string and the suggestion starts exactly where the caret is.
                (Text(query).foregroundStyle(.clear) + Text(ghost).foregroundStyle(.tertiary))
                    .font(Face.title3)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                TextField("", text: $query, prompt: Text("Go to anything, or type a prefix"))
                    .textFieldStyle(.plain)
                    .font(Face.title3)
                    .focused($fieldFocused)
                    .onSubmit(runSelected)
                    // The field owns first responder while the palette is open, so the
                    // ancestor never receives arrow keys on macOS.
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.tab) { acceptCompletion() }
                    .onKeyPress(.rightArrow) { acceptCompletion() }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            Text("\(documents.count) documents · \(commands.count) commands")
                .font(Face.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.roomy)
    }

    @ViewBuilder
    private var results: some View {
        if mode == .help {
            Text("Every shortcut, over whatever you were doing.")
                .font(Face.control)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.gutter)
                .onAppear { sources.help(); dismiss() }
        } else if entries.isEmpty {
            Text(needle.isEmpty
                 ? "Type to search. Every command is here, whether or not it has a key."
                 : "Nothing matches “\(needle)”.")
            .font(Face.control)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.gutter)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.hair) {
                    ForEach(Array(sections.enumerated()), id: \.element.title) { _, section in
                        Text(section.title)
                            .font(Face.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.roomy)
                            .padding(.top, Space.step)
                        ForEach(section.entries) { entry in
                            let position = entries.firstIndex { $0.id == entry.id } ?? 0
                            row(entry, selected: position == index)
                                .contentShape(Rectangle())
                                .onTapGesture { index = position; runSelected() }
                        }
                    }
                }
                .padding(Space.snug)
            }
            .frame(maxHeight: 380)
        }
    }

    /// The entries under the headings the artboard names, in the order they are listed.
    private var sections: [(title: String, entries: [Entry])] {
        if showsStarters { return [("Start with", entries)] }
        var out: [(String, [Entry])] = []
        if !matchingPlaces.isEmpty { out.append(("Go to", matchingPlaces.map(Entry.place))) }
        if !matchingPages.isEmpty {
            out.append((mode == .page ? "Page" : "In this document", matchingPages.map(Entry.page)))
        }
        if !matchingDocuments.isEmpty { out.append(("Documents", matchingDocuments.map(Entry.document))) }
        if !elsewhereInLibrary.isEmpty {
            out.append(("In the library", elsewhereInLibrary.map(Entry.place)))
        }
        if !textHits.isEmpty {
            out.append(("In the text · \(textHits.count) match\(textHits.count == 1 ? "" : "es")",
                        textHits.map(Entry.text)))
        }
        if !matchingCommands.isEmpty { out.append(("Commands", matchingCommands.map(Entry.command))) }
        if !matchingSettings.isEmpty { out.append(("Settings", matchingSettings.map(Entry.setting))) }
        return out
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.roomy) {
                hint("↩", "open")
                hint("↑↓", "move")
                hint("⎋", "close")
                Spacer()
            }
            Text(ghost.isEmpty
                 ? "> commands · # tags · @ projects · / in this document · : page · ? help"
                 : "⇥ or → completes “\(completion ?? "")”")
                .foregroundStyle(.secondary)
        }
        .font(Face.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
    }

    @ViewBuilder
    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: Space.step) {
            switch entry {
            case .starter(let mode):
                let starter = Self.starters.first { $0.mode == mode }
                Text(String(mode.rawValue))
                    .font(Face.mono.weight(.bold))
                    .frame(width: Metric.keyWidth)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(starter?.title ?? "").lineLimit(1)
                Spacer(minLength: Space.step)
                Text(starter?.detail ?? "")
                    .font(Face.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            case .setting(let setting):
                Image(systemName: setting.opensSettings ? "gearshape" : "switch.2")
                    .font(Face.micro)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(setting.title).lineLimit(1)
                Spacer(minLength: Space.step)
                Text(setting.value())
                    .font(Face.caption.weight(setting.opensSettings ? .regular : .semibold))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            case .place(let place):
                Image(systemName: place.kind.icon)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(place.title).lineLimit(1)
                Spacer(minLength: Space.step)
                Text(place.detail)
                    .font(Face.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            case .document(let item):
                Image(systemName: "doc.text")
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(item.currentFilename).lineLimit(1)
                Spacer(minLength: Space.step)
                Text(item.root.lastPathComponent)
                    .font(Face.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            case .text(let hit):
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text("“\(hit.snippet)”")
                    .font(Face.page)
                    .lineLimit(1)
                Spacer(minLength: Space.step)
                Text([hit.author, hit.page.map { "p. \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(Face.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            case .page(let hit):
                Image(systemName: "book.pages")
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(hit.line).lineLimit(1)
                Spacer(minLength: Space.step)
                Text("p. \(hit.page)")
                    .font(Face.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            case .command(let command):
                Image(systemName: "chevron.right")
                    .font(Face.micro)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(command.title).lineLimit(1)
                Spacer(minLength: Space.step)
                Text(command.scope.label)
                    .font(Face.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                if let shortcut = Keymap.shared.shortcut(for: command) {
                    Text(shortcut.display)
                        .font(Face.mono.weight(.semibold))
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.step)
        .background(selected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: Metric.control))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: Space.tight) {
            Text(key)
                .font(Face.mono.weight(.bold))
                .padding(.horizontal, Space.tight)
                .padding(.vertical, Space.hair)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Metric.keyCap))
            Text(meaning)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        index = min(max(index + delta, 0), entries.count - 1)
        return .handled
    }

    private func runSelected() {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        if case .starter(let mode) = entry {
            query = String(mode.rawValue)
            return
        }
        if case .setting(let setting) = entry {
            // A setting you can see the state of is one you may want to flip twice, so the
            // field stays where it is. Handing over to the Settings window closes, since
            // that window is now the one in front.
            setting.act()
            if setting.opensSettings { dismiss() }
            return
        }
        if case .text(let hit) = entry {
            // Matching a text hit to a document is an async round trip to the
            // library (see `matchingItem`), so it cannot dismiss up front the way
            // the other cases do: closing the palette before the match answers
            // would close it over a hit that turns out to match nothing.
            Task { await openTextHit(hit) }
            return
        }
        // Dismiss first: a command that opens a sheet of its own cannot do it from
        // underneath this one.
        dismiss()
        switch entry {
        case .command(let command): run(command)
        case .document(let item): open(item)
        case .place(let place): place.go()
        case .page(let hit): hit.go()
        case .text, .starter, .setting: break
        }
    }

    /// A hit in the library's text is a document first: open the file it came from, and
    /// the page it was found on if the snippet knew one. Only dismisses the palette once
    /// a match is actually found, so a hit that cannot be traced to anything leaves the
    /// palette open instead of quietly closing over nothing.
    private func openTextHit(_ hit: TextHit) async {
        guard let item = await matchingItem(for: hit) else { return }
        dismiss()
        open(item)
        if let page = hit.page, let go = sources.goToPage { go(page) }
    }

    /// Resolves a text hit to the item it came from.
    ///
    /// A hit's `title` is whatever the library indexed the document's Title metadata
    /// as, which is empty for a PDF that carries none and can drift from what the
    /// document is titled now -- matching on it, as this used to, silently selects
    /// nothing for exactly those files. The library's own id is stable, so it is asked
    /// for the paths on record for that id, and those are compared against `currentURL`
    /// with symlinks resolved on both sides, the same way `Item.key` already has to
    /// (a path built by the caller and one handed back by the filesystem can name the
    /// same file with different strings). Title matching only steps in when the library
    /// cannot say what path the hit came from at all -- falling back to it once a path
    /// is known but simply matches nothing open right now would risk landing on some
    /// other document that happens to share a title, which is the bug this replaces.
    private func matchingItem(for hit: TextHit) async -> Item? {
        var paths: Set<String> = []
        if let library = Library.shared,
           let locations = try? await library.locations(forDocument: hit.documentID) {
            paths = Set(locations.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        }
        if !paths.isEmpty {
            // The plain path first: resolving one is a filesystem call each, and almost no
            // shelf is reached through a link, so the whole collection is only resolved
            // when the plain comparison came up empty.
            if let direct = documents.first(where: { paths.contains($0.currentURL.path) }) {
                return direct
            }
            return documents.first { paths.contains($0.currentURL.resolvingSymlinksInPath().path) }
        }
        return documents.first(where: { $0.currentFilename == hit.title })
            ?? documents.first(where: { $0.documentInfo["Title"] == hit.title })
    }
}
