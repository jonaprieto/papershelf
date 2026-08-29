import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

struct ResultsPane: View {
    @ObservedObject var runner: Runner
    @ObservedObject var covers: Covers
    @Binding var expanded: Set<String>
    @Binding var selected: String?
    let sourceCount: Int
    let previewIsCurrent: Bool
    let passwords: [String]
    let reading: Bool
    let watching: Bool
    @ObservedObject var palette: Palette
    let rules: NameRules
    let chooseFiles: () -> Void
    let preview: () -> Void
    let apply: () -> Void
    let applyOne: (Item, String) -> Void

    private var hasSources: Bool { sourceCount > 0 }


    @AppStorage("viewMode") private var mode: ViewMode = .catalogue
    @AppStorage("aiModel") private var aiModel = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var aiUseEnvironment = true
    @AppStorage("autoIdentify") private var autoIdentify = false
    @AppStorage("sortOrder") private var sortOrder: ItemSort = .folder
    @AppStorage("bibStandard") private var bibStandard: BibStandard = .biblatex
    @ObservedObject private var kept: KeptBibtex = .shared
    /// The inspector's width when the current divider drag began. Nil when nothing is
    /// being dragged.
    @State private var dragAnchor: CGFloat?
    @AppStorage("sortDescending") private var sortDescending = false
    /// Hides everything already decided, so what is left is what is still asking for a
    /// decision. A filter like any other, and it says so in the filter bar.
    @AppStorage("onlyUndecided") private var onlyUndecided = false
    /// Kept in step with the grid so the arrow keys can move by a row.
    @State private var gridColumns = 1
    @State private var showingShortcuts = false
    @StateObject private var converting = Converting()
    @State private var showingMarkdown = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var confirmingBatchAI = false
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 460
    @AppStorage("contentsShown") private var contentsShown = false
    @AppStorage("inspectorCollapsed") private var inspectorCollapsed = false
    @StateObject private var annotator = Annotator()
    @State private var addingNote = false
    @State private var noteText = ""
    @StateObject private var tagIndex = CatalogueTags()
    /// Which of the four library lists the shelf is showing, shared with the sidebar that
    /// sets it.
    @ObservedObject private var shelves: Shelves = .shared
    @ObservedObject private var regions: Regions = .shared
    /// Remembers the last filter result. The grid, the folder tree and the "N of M shown"
    /// label each need it, and each used to recompute it: three passes over the whole
    /// collection per render, and again on every tick of a window resize because the grid
    /// asks from inside a `GeometryReader`.
    @State private var filter = VisibleFilter()
    /// The file a "New Tag…" prompt was opened for. Non-nil drives the sheet.
    @State private var taggingItem: Item?
    @State private var newTagName = ""
    /// Set by right-clicking a folder here, or by the file explorer publishing
    /// `.openFolderInCatalogue`: narrows what the catalogue shows to files under one
    /// folder, on top of whatever the search box is doing.
    @State private var folderScope: URL?

    @AppStorage("bibOrder") private var bibOrder: BibOrder = .alphabetical
    @AppStorage("bibCompleteOnly") private var bibCompleteOnly = false
    @AppStorage("bibType") private var bibType: BibType = .book
    @State private var choosingMoveTarget = false
    @AppStorage("bibLineWidth") private var bibLineWidth = 80
    @AppStorage("bibIndent") private var bibIndent = 2
    @AppStorage("bibAlign") private var bibAlign = true
    @AppStorage("bibDelimiter") private var bibDelimiter: BibStyle.Delimiter = .braces
    @AppStorage("bibTrailingComma") private var bibTrailingComma = true
    @AppStorage("bibBlankLines") private var bibBlankLines = true
    @AppStorage("bibSortFields") private var bibSortFields = false
    @AppStorage("bibDropAllCaps") private var bibDropAllCaps = false
    @AppStorage("bibOmitFile") private var bibOmitFile = false

    private var bibStyle: BibStyle {
        BibStyle(lineWidth: bibLineWidth,
                 indent: String(repeating: " ", count: max(0, bibIndent)),
                 align: bibAlign,
                 delimiter: bibDelimiter,
                 trailingComma: bibTrailingComma,
                 blankLines: bibBlankLines,
                 sortFields: bibSortFields,
                 dropAllCaps: bibDropAllCaps,
                 omit: bibOmitFile ? ["file"] : [])
    }
    @AppStorage("bibShowsFile") private var bibShowsFile = false
    @State private var draft = ""
    /// The suggestion the draft started from, so an edit of yours can be told apart from
    /// a name you simply have not touched.
    @State private var suggestion = ""
    @FocusState private var editingName: Bool
    /// Held by the pane itself so the letter keys work the moment a preview lands, with
    /// no click needed to give something focus first.
    @FocusState private var paneFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var keyMonitor: Any?
    @State private var showingPalette = false
    @State private var paletteTags: [TagCount] = []
    @State private var paletteProjects: [ProjectSummary] = []
    /// The document the reader is open on, by key. Nil means the browser has the middle
    /// of the window.
    ///
    /// The page used to be beside every view, so a shelf of covers spent half a window on
    /// a PDF nobody had asked to open. The middle region shows one thing now: the
    /// collection, or a document.
    @State private var reader: String?

    /// Whether the page is one of the panes.
    ///
    /// The list is the reviewer -- a name is decided against the page it belongs to -- and
    /// the reader is the page. The shelf, the bibliography and the duplicates view are
    /// about a collection and show none.
    private var showsPage: Bool { reader != nil || reading || mode == .list }

    /// Whether the browser keeps the middle. Reading mode and the reader both take it.
    private var showsBrowser: Bool { !reading && reader == nil }

    /// The document the reader is on, falling back to the selection when the key no
    /// longer names a file (a rename applied, a source removed).
    private var readerItem: Item? {
        guard let reader else { return nil }
        return runner.results.first { $0.key == reader }
    }

    private func openReader(_ key: String?) {
        guard let key else { return }
        selected = key
        reader = key
    }

    /// One rung of the ⎋ ladder: out of the reader, back into the collection.
    private func closeReader() {
        reader = nil
    }

    private var selectedItem: Item? {
        runner.results.first { $0.key == selected }
    }

    /// The keys the search should show: Runner's own answer for the fields it
    /// understands (name, folder, status, size, pages, year, text), narrowed further by
    /// any `tag:` terms and by `folderScope`, neither of which Runner knows anything
    /// about. Nil means nothing is filtering at all, the same meaning `runner.matchingKeys`
    /// already carries on its own.
    private var visibleKeys: Set<String>? {
        filter.keys(matching: VisibleFilter.Signature(
            results: runner.resultsToken,
            matching: runner.matchingToken,
            tags: tagIndex.revision,
            query: query,
            scope: folderScope,
            undecidedOnly: onlyUndecided && mode == .list,
            decisions: runner.reviewed,
            list: shelves.current,
            lists: shelves.revision
        ), compute: computeVisibleKeys)
    }

    /// The filter itself, unchanged. It is called at most once per body pass now, and not
    /// at all when nothing it reads has moved.
    private func computeVisibleKeys() -> Set<String>? {
        var current: [Item]?
        if let keys = runner.matchingKeys {
            current = runner.results.filter { keys.contains($0.key) }
        }
        let tagTerms = Query(query).terms.filter { $0.field == "tag" }
        if !tagTerms.isEmpty {
            let base = current ?? runner.results
            let tagQuery = PreparedQuery(Query(queryText(for: tagTerms)))
            current = base.filter { matches(Searchable(item: $0, tags: tagIndex.tags(for: $0)), tagQuery) }
        }
        if let folderScope {
            let base = current ?? runner.results
            let scope = FolderScope(folderScope)
            current = base.filter { scope.contains($0) }
        }
        if shelves.current != .all {
            let base = current ?? runner.results
            current = base.filter { shelves.contains($0, in: shelves.current) }
        }
        if onlyUndecided && mode == .list {
            let base = current ?? runner.results
            current = base.filter { runner.decision(for: $0) == nil }
        }
        return current.map { Set($0.map(\.key)) }
    }

    /// Rebuilds a query string from a subset of already-parsed terms, quoting a value
    /// back up if it had to have been quoted to produce it. Used both to isolate the
    /// `tag:` terms for `visibleKeys` and to strip them back out before anything is
    /// handed to Runner (see `strippingTagTerms`).
    private func queryText(for terms: [Query.Term]) -> String {
        terms.map { term in
            let value = term.value.contains(" ") ? "\"\(term.value)\"" : term.value
            guard let field = term.field else { return value }
            let symbol = term.comparison == .greater ? ">" : term.comparison == .less ? "<" : ":"
            return "\(field)\(symbol)\(value)"
        }.joined(separator: " ")
    }

    /// What Runner's own search should be asked, with any `tag:` terms removed: Runner
    /// has no idea what a document's tags are, and asking its matcher to judge a field it
    /// cannot see would fail every file rather than the handful the catalogue itself can
    /// tell were never tagged (see the "tag" case in `Search.swift`'s `matches`).
    private func strippingTagTerms(_ text: String) -> String {
        queryText(for: Query(text).terms.filter { $0.field != "tag" })
    }

    /// One folder, prepared once for a whole pass over the files.
    ///
    /// This used to resolve symlinks for the folder and then again for every file, on
    /// every pass. Resolving a path is a filesystem call: about nine milliseconds per
    /// thousand files, twice over, on a pass a view body could trigger several times a
    /// frame. Now the plain paths are compared first, and the filesystem is only asked
    /// about a file when the folder itself is reached through a symlink and the plain
    /// comparison came up empty.
    struct FolderScope {
        let plain: String
        let resolved: String
        let symlinked: Bool

        init(_ folder: URL) {
            plain = folder.path
            resolved = folder.resolvingSymlinksInPath().path
            symlinked = plain != resolved
        }

        func contains(_ item: Item) -> Bool {
            let path = item.currentURL.path
            if under(plain, path) || under(resolved, path) { return true }
            guard symlinked else { return false }
            return under(resolved, item.currentURL.resolvingSymlinksInPath().path)
        }

        private func under(_ folder: String, _ path: String) -> Bool {
            path == folder || path.hasPrefix(folder + "/")
        }
    }

    /// Scopes the catalogue to one folder's files, switching to the view that shows them
    /// as a shelf. The one function both the local right-click and the notification from
    /// the file explorer (`.openFolderInCatalogue`) call, so the two stay in step.
    private func openFolder(_ url: URL) {
        folderScope = url
        mode = .catalogue
    }

    /// Shows only what carries one tag, by writing the search the search box already
    /// understands rather than adding a second, parallel notion of scope. Any folder scope
    /// is dropped: a tag spans the shelf, and leaving a folder filter on top of it would
    /// silently show a fraction of the tag.
    private func showTag(_ name: String) {
        folderScope = nil
        query = Query.tagSearch(name)
        mode = .catalogue
    }

    private var aiClient: AIClient {
        AIClient(baseURL: aiBaseURL, model: aiModel,
                 apiKey: resolvedKey(useEnvironment: aiUseEnvironment))
    }

    private var aiReady: Bool { !aiClient.apiKey.isEmpty }

    private func identifySelected() {
        guard let item = selectedItem, aiReady else { return }
        Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
    }

    private func currentName(_ item: Item) -> String {
        if case .confirmed(let name) = runner.decision(for: item) { return name }
        return item.destinationName
    }

    var body: some View {
        withDialogs(withKeys(core))
    }

    private var core: some View {
        titled(place)
    }

    private func titled<V: View>(_ view: V) -> some View {
        view
            .navigationTitle(placeTitle)
            .navigationSubtitle(placeSubtitle)
    }

    private var place: some View {
        Group {
            if runner.busy {
                busyState
            } else if runner.results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if !reading {
                        filterBar
                        Divider()
                    }
                    split
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// The chain is split in two because one body carrying all of it is past what the
    /// type-checker will work through in reasonable time. Generic wrappers are checked
    /// independently, which is what makes it compile.
    private func withKeys<V: View>(_ view: V) -> some View {
        view
            .focusable()
            .focusEffectDisabled()
            .focused($paneFocused)
            .animation(.easeOut(duration: 0.18), value: runner.results.count)
            .onChange(of: runner.results.count) { _, _ in
            // Open the first level only, so a run lands looking like `ls` rather than
            // one closed folder or the whole tree at once.
            expanded.formUnion(runner.tree.filter { $0.children != nil }.map(\.id))
            ensureSelection()
        }
            .onChange(of: selected) { previous, new in
            // Folder rows carry no tag, so clicking one clears the selection. Put the
            // file back rather than letting the inspector swap out from under you.
            if new == nil, let previous, runner.results.contains(where: { $0.key == previous }) {
                selected = previous
                return
            }
            loadDraft()
        }
            .onAppear {
            ensureSelection()
            installKeyMonitor()
        }
        // A restyle rewrites the suggestions under the current selection.
            .onChange(of: runner.revision) { _, _ in refreshSuggestion() }
            .onChange(of: sortOrder) { _, order in
            sortDescending = order.descendsByDefault
            runner.sortResults(by: order, descending: sortDescending)
        }
            .onChange(of: sortDescending) { _, down in
            runner.sortResults(by: sortOrder, descending: down)
        }
            .onChange(of: runner.results.count) { _, count in
            guard count > 0, sortOrder != .folder else { return }
            runner.sortResults(by: sortOrder, descending: sortDescending)
        }
            .onDisappear(perform: removeKeyMonitor)
        // Which regions are actually drawn, so ⌃⇥ skips what is not on screen and ⌃1-⌃5
        // opens what is collapsed rather than appearing to do nothing.
            .onChange(of: regionSignature, initial: true) { _, _ in
            var drawn: Set<Region> = [.document, .status]
            if !reading { drawn.insert(.sidebar) }
            if !inspectorCollapsed { drawn.insert(.inspector) }
            if showsPage && contentsShown && !annotator.contents.isEmpty { drawn.insert(.contents) }
            regions.available = drawn
        }
            .onChange(of: regions.focused) { _, region in
            if region == .document { listFocused = true }
        }
        // Reruns whenever the result set changes size, resolving any items the tag
        // index has not seen yet. Already-resolved items are skipped inside `refresh`,
        // so this costs nothing extra when nothing new has arrived.
            .task(id: runner.results.count) { await tagIndex.refresh(items: runner.results) }
            .onReceive(NotificationCenter.default.publisher(for: .openFolderInCatalogue)) { note in
            guard let path = note.userInfo?["path"] as? String else { return }
            openFolder(URL(fileURLWithPath: path))
        }
            .onReceive(NotificationCenter.default.publisher(for: .showTagInCatalogue)) { note in
            guard let name = note.userInfo?["tag"] as? String else { return }
            showTag(name)
        }
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
            .sheet(isPresented: $showingMarkdown) {
                if let item = selectedItem {
                    MarkdownSheet(item: item, passwords: passwords, converting: converting)
                }
            }
            .sheet(item: $taggingItem) { item in
                NewTagSheet(name: $newTagName) { name in
                    Task { await tagIndex.add(name, to: item) }
                    taggingItem = nil
                }
            }
            .fileImporter(isPresented: $choosingMoveTarget,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { outcome in
            guard case .success(let urls) = outcome, let folder = urls.first,
                  let item = selectedItem else { return }
            runner.move(item, to: folder)
            advance()
        }
            .confirmationDialog("Ask AI for \(runner.pendingCount) names?",
                            isPresented: $confirmingBatchAI) {
            Button("Send \(runner.pendingCount) requests") {
                Task { await runner.identifyPending(client: aiClient, passwords: passwords, rules: rules) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One request per file, each carrying the filename and the first pages' text. "
                 + "You are billed by \(aiModel)'s provider.")
        }
            .alert("The service could not be reached", isPresented: aiErrorShown) {
            Button("OK") { runner.ai.error = nil }
        } message: {
            Text(runner.ai.error ?? "")
        }
        // Built here rather than in ContentView's toolbar because this is where the query
        // and the mode live, and SwiftUI merges toolbars down the hierarchy. Moving the
        // state up instead would have meant reimplementing the search field's behaviour —
        // metadata filtering live, `text:` waiting for Return, `/` to focus — around a
        // binding, and that behaviour is the useful part.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .fixedSize()
                .tip("Which view of the same files", key: "⌘1 to ⌘4")
            }
            ToolbarItem(placement: .primaryAction) {
                searchField
            }
            ToolbarItemGroup(placement: .primaryAction) {
                contextualActions
            }
        }
        .sheet(isPresented: $showingPalette) {
            CommandPalette(
                commands: Self.performable.filter { $0 != .palette },
                documents: runner.results,
                run: { perform($0) },
                open: { openReader($0.key) },
                sources: paletteSources
            )
        }
        .task(id: showingPalette) { await loadPalettePlaces() }
    }

    /// What this view can do to what is in it, in the place a person looks for an
    /// action.
    ///
    /// They were in the results bar, which is also where progress and the counts were, so
    /// the bar changed shape while work was running and the content under it jumped. Here
    /// the prominent one is always the action that touches disk, and everything rarer is
    /// one menu behind it.
    @ViewBuilder
    private var contextualActions: some View {
        switch mode {
        case .duplicates:
            Button {
                runner.findDuplicates(passwords: passwords)
            } label: {
                Label(runner.duplicates.isEmpty ? "Find duplicates" : "Recheck",
                      systemImage: "doc.on.doc")
            }
            .disabled(runner.findingDuplicates)
            .tip("Compare every file by size, then by bytes", key: "⌘D")

            Button("Trash \(runner.identicalExtras) spare\(runner.identicalExtras == 1 ? "" : "s")") {
                runner.markIdenticalExtras()
                ensureSelection()
            }
            .disabled(runner.identicalExtras == 0)
            .tip("Only files that are identical byte for byte. A likely match is never batched.")
        default:
            Button(action: preview) {
                Label("Plan", systemImage: "list.bullet.rectangle")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!hasSources || runner.busy)
            .keyboardShortcut("p", modifiers: .command)
            .tip("Read-only: works out the new names, touches nothing", key: "⌘P")

            Button(action: apply) {
                Label(canApply ? "Apply \(runner.actionable)" : "Apply",
                      systemImage: "checkmark.circle")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
            .keyboardShortcut(.return, modifiers: .command)
            .tip("Carry out the reviewed plan on disk", key: "⌘Return")
        }

        Menu {
            Button("Confirm everything still pending") {
                runner.confirmAllPending()
                ensureSelection()
            }
            .disabled(runner.pendingCount == 0)
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            if aiReady {
                Button("Ask AI for \(runner.pendingCount) name\(runner.pendingCount == 1 ? "" : "s")") {
                    confirmingBatchAI = true
                }
                .disabled(runner.pendingCount == 0)
            }

            Divider()
            Button("Find duplicates") { runner.findDuplicates(passwords: passwords) }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Copy the catalogue as Markdown") {
                copyText(markdownCatalogue(runner.results, known: runner.ai.guesses))
            }
            Button("Copy the bibliography as Markdown") {
                runner.ensureBib()
                copyText(markdownBibliography(runner.bib))
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .disabled(runner.results.isEmpty)
    }

    /// Applying needs a preview that still matches the settings, every file reviewed, and
    /// at least one of them left to act on.
    private var canApply: Bool {
        previewIsCurrent && runner.allReviewed && runner.actionable > 0 && !runner.busy
    }

    /// Everywhere the palette can send you, and everything it can look inside.
    ///
    /// Assembled here because this is the one view that knows all four answers: which
    /// list the shelf is on, which folders the results are in, which document is open,
    /// and which projects and tags the library holds.
    private var paletteSources: PaletteSources {
        var places: [PalettePlace] = SmartList.allCases.map { list in
            PalettePlace(id: "list:" + list.rawValue, title: list.title,
                         detail: list.explanation, kind: .list) {
                shelves.current = list
                folderScope = nil
            }
        }
        places += runner.tree.filter { $0.children != nil }.prefix(40).map { node in
            PalettePlace(id: "folder:" + node.id, title: node.name,
                         detail: "\(node.children?.count ?? 0) documents", kind: .folder) {
                openFolder(URL(fileURLWithPath: node.id))
            }
        }
        places += paletteProjects.map { project in
            PalettePlace(id: "project:\(project.id)", title: project.name,
                         detail: "project · \(project.documentCount) documents", kind: .project) {
                NotificationCenter.default.post(name: .openProject, object: nil,
                                                userInfo: ["id": project.id])
            }
        }
        places += paletteTags.map { tag in
            PalettePlace(id: "tag:" + tag.name, title: tag.name,
                         detail: "\(tag.documents) documents", kind: .tag) {
                showTag(tag.name)
            }
        }

        return PaletteSources(
            places: places,
            inTheText: { text in
                guard let library = Library.shared else { return [] }
                return (try? await library.fullTextHits(text, limit: 4)) ?? []
            },
            inThisDocument: { text in
                annotator.find(text).map { hit in
                    PageHit(id: "doc-\(hit.page)-\(hit.line.prefix(24))", page: hit.page,
                            line: hit.line, go: hit.jump)
                }
            },
            goToPage: annotator.view == nil ? nil : { annotator.go(toPage: $0) },
            help: { showingShortcuts = true }
        )
    }

    /// Loaded when the palette opens rather than kept in step: it is two queries, and
    /// they are only ever read by one field that is not usually on screen.
    private func loadPalettePlaces() async {
        guard showingPalette, let library = Library.shared else { return }
        paletteTags = (try? await library.tagCounts()) ?? []
        let projects = (try? await library.projects()) ?? []
        var summaries: [ProjectSummary] = []
        for project in projects {
            let count = ((try? await library.members(ofProject: project.id)) ?? []).count
            summaries.append(ProjectSummary(id: project.id, name: project.name, documentCount: count))
        }
        paletteProjects = summaries
    }

    /// Hoisted out of the modifier chain: an inline Binding there pushed the whole body
    /// past what the type-checker will work through.
    private var aiErrorShown: Binding<Bool> {
        Binding(get: { runner.ai.error != nil }, set: { if !$0 { runner.ai.error = nil } })
    }

    // MARK: Keys

    /// A List on macOS is an NSTableView, and its type-select eats plain letters to jump
    /// between rows, so `onKeyPress` on an ancestor never sees them. A local monitor runs
    /// ahead of the responder chain instead.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Which commands can be heard here. This pane is where a plan is decided, so the
    /// reviewing keys are live along with everything scoped anywhere or to the library.
    private var activeScope: Command.Scope { .reviewing }

    /// The commands that do not need a file in front of them, and so must still work on
    /// an empty shelf — which is exactly when someone reaches for the palette.
    private static let alwaysAvailable: Set<Command> = [
        .palette, .focusSearch, .shortcuts,
        .focusSidebar, .focusContents, .focusDocument, .focusInspector, .focusStatus,
        .nextRegion, .previousRegion,
    ]

    private func handle(_ event: NSEvent) -> Bool {
        guard !runner.busy else { return false }
        if event.keyCode == 53 { return escape() }   // ⎋
        let match = Keymap.shared.command(for: event, in: activeScope)
        if let match, Self.alwaysAvailable.contains(match) { return perform(match) }
        guard !runner.results.isEmpty, selectedItem != nil else { return false }
        let bare = match.flatMap { Keymap.shared.shortcut(for: $0) }?.modifiers.isEmpty ?? true

        // Anything carrying a modifier is app-level and must work wherever focus is,
        // including while a name is being typed.
        if let match, !bare { return perform(match) }

        // Past here every binding is a bare key, which belongs to whatever is being typed
        // into. A table view is the exception: its type-select is exactly what this
        // monitor exists to replace.
        if searchFocused { return false }
        if let responder = event.window?.firstResponder,
           responder is NSTextView || (responder is NSControl && !(responder is NSTableView)) {
            return false
        }

        // The lists are table views and move themselves; the catalogue is a grid and has
        // no such thing, so the arrows are handled here when a table is not in charge.
        let onATable = event.window?.firstResponder is NSTableView
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        if !onATable {
            // In a grid a row is a row: up and down cross `gridColumns` items, while left
            // and right move to the neighbour.
            let row = mode == .catalogue ? max(1, gridColumns) : 1
            switch event.keyCode {
            case 125: step(by: row); return true    // down
            case 126: step(by: -row); return true   // up
            case 124: step(by: 1); return true      // right
            case 123: step(by: -1); return true     // left
            default: break
            }
        } else if arrows.contains(event.keyCode) {
            // Leave them to the table, the way they always were, rather than letting the
            // arrow alternates on next/previous file take them away from it.
            return false
        }

        guard let match else { return false }
        return perform(match)
    }

    /// Everything that decides which regions exist right now.
    private var regionSignature: String {
        "\(reading)\(inspectorCollapsed)\(contentsShown)\(annotator.contents.isEmpty)\(showsPage)"
    }

    /// One key, always meaning "out of this, into what contains it".
    ///
    /// Returning false hands ⎋ on to whoever else wants it -- a sheet, a popover, the
    /// menu bar -- which is what keeps the last rung from swallowing a dismissal.
    private func escape() -> Bool {
        // A sheet gets its own ⎋ first. This monitor runs ahead of the responder chain
        // for the whole app, so swallowing the key here would leave the palette with no
        // way to close but the mouse.
        guard !showingPalette, !showingShortcuts, !showingMarkdown, taggingItem == nil,
              !confirmingBatchAI, !choosingMoveTarget
        else { return false }
        switch Regions.escape(editingField: editingName,
                              rowFocused: regions.rowFocused,
                              filtering: !query.isEmpty || folderScope != nil
                                          || shelves.current != .all,
                              insidePlace: reader != nil) {
        case .leaveField:
            // Keeps what was typed: a second press would undo it, and that is a different
            // decision from leaving the field.
            editingName = false
            listFocused = true
            regions.rowFocused = true
        case .leaveRow:
            regions.rowFocused = false
        case .clearFilters:
            query = ""
            folderScope = nil
            shelves.current = .all
            runner.search("", passwords: passwords)
        case .leavePlace:
            closeReader()
        case .nothing:
            return false
        }
        return true
    }

    /// Exactly the commands `perform` carries out, in the order the palette lists them.
    ///
    /// Kept beside the switch below and used to build the palette, so a line can never be
    /// offered that would do nothing. Anything absent here is still reachable — it simply
    /// belongs to a different surface, and its key event falls through to whoever owns it.
    static let performable: [Command] = [
        .confirm, .editName, .askAI, .copyCitation, .applyOne,
        .skip, .skipFolder, .moveTo, .trash, .reopen,
        .nextFile, .previousFile, .confirmAllPending,
        .viewList, .viewCatalogue, .viewBibliography, .viewDuplicates,
        .findDuplicates, .revealInFinder, .openExternally,
        .highlight1, .highlight2, .highlight3, .highlight4, .highlight5,
        .addNote, .nextMark, .previousMark,
        .focusSidebar, .focusContents, .focusDocument, .focusInspector, .focusStatus,
        .nextRegion, .previousRegion, .newTag,
        .focusSearch, .shortcuts, .palette,
    ]

    /// Carries out one command, whatever asked for it.
    ///
    /// The monitor above and the command palette both come through here, which is what
    /// makes a rebound key and a palette entry do the same thing — and what stops the
    /// palette from growing its own quietly different copy of `confirm()`.
    ///
    /// Returning false means "not mine": the key event carries on to whatever else might
    /// want it, which is how ⌘↩ still reaches the Apply button in the toolbar.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        switch command {
        case .viewList: mode = .list
        case .viewCatalogue: mode = .catalogue
        case .viewBibliography: mode = .bibliography
        case .viewDuplicates: mode = .duplicates
        case .revealInFinder: revealInFinder()
        case .findDuplicates: runner.findDuplicates(passwords: passwords)
        case .confirmAllPending:
            runner.confirmAllPending()
            ensureSelection()
        case .confirm: confirm()
        case .editName: editingName = true
        case .skip: skip()
        case .skipFolder: skipFolder()
        case .applyOne: applyNow()
        case .askAI: identifySelected()
        case .moveTo: choosingMoveTarget = true
        case .openExternally: openInViewer()
        case .copyCitation: copyCitation()
        case .shortcuts: showingShortcuts = true
        case .palette: showingPalette = true
        case .focusSearch: searchFocused = true
        case .trash: markDeleted()
        case .reopen: reopenSelected()
        case .nextFile: step(by: 1)
        case .previousFile: step(by: -1)

        case .highlight1: highlight(colourAt: 0)
        case .highlight2: highlight(colourAt: 1)
        case .highlight3: highlight(colourAt: 2)
        case .highlight4: highlight(colourAt: 3)
        case .highlight5: highlight(colourAt: 4)
        case .addNote:
            guard annotator.selectedMark != nil || annotator.hasSelection else { return false }
            addingNote = true
        case .nextMark: stepMark(by: 1)
        case .previousMark: stepMark(by: -1)

        case .focusSidebar: regions.focus(.sidebar)
        case .focusContents:
            guard !annotator.contents.isEmpty else { return false }
            contentsShown = true
            regions.focus(.contents)
        case .focusDocument:
            listFocused = true
            regions.focus(.document)
        case .focusInspector:
            inspectorCollapsed = false
            regions.focus(.inspector)
        case .focusStatus: regions.focus(.status)
        case .nextRegion: regions.step(1)
        case .previousRegion: regions.step(-1)
        case .newTag:
            guard let item = selectedItem else { return false }
            newTagName = ""
            taggingItem = item

        default: return false
        }
        return true
    }

    /// Paints the selection in the nth highlighter, or recolours the mark you are on when
    /// there is nothing selected — which is what a number key means once a mark is under
    /// the cursor rather than a fresh run of text.
    private func highlight(colourAt index: Int) {
        guard palette.styles.indices.contains(index) else { return }
        let colour = palette.styles[index].nsColor
        if annotator.hasSelection {
            _ = annotator.highlightSelection(colour: colour)
        } else if let selected = annotator.selectedMark,
                  let mark = annotator.marks.first(where: { $0.id == selected }) {
            annotator.setColour(colour, on: mark)
        }
    }

    /// Moves to the next mark in the document and scrolls the page to it, since a
    /// highlight on a page you are not looking at is invisible by definition.
    private func stepMark(by delta: Int) {
        guard !annotator.marks.isEmpty else { return }
        let current = annotator.marks.firstIndex { $0.id == annotator.selectedMark }
        let next = ((current ?? (delta > 0 ? -1 : 0)) + delta + annotator.marks.count)
            % annotator.marks.count
        annotator.jump(to: annotator.marks[next])
    }

    /// Leaving the name field has to hand focus somewhere, or Return drops it on the
    /// floor: the row stops looking selected even though it still is.
    private func loadDraft() {
        if let item = selectedItem { runner.loadExcerpt(for: item, passwords: passwords) }
        editingName = false
        draft = selectedItem.map(currentName) ?? ""
        suggestion = selectedItem?.destinationName ?? ""
        if !runner.results.isEmpty { listFocused = true }
        askOnArrival()
    }

    /// With the toggle on, landing on a file that is still undecided and has never been
    /// looked at asks the model for a name. Guarded on all three, so browsing back over
    /// files already dealt with costs nothing.
    private func askOnArrival() {
        guard autoIdentify, aiReady, let item = selectedItem,
              runner.decision(for: item) == nil,
              runner.ai.guesses[item.key] == nil,
              !runner.ai.isThinking(item)
        else { return }
        Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
    }

    private func refreshSuggestion() {
        guard let item = selectedItem else { return }
        if draft == suggestion { draft = item.destinationName }
        suggestion = item.destinationName
    }

    private func reopenSelected() {
        guard let item = selectedItem else { return }
        runner.reopen(item)
        loadDraft()
    }

    /// Moves through the list without deciding anything.
    /// Moves by `offset`, clamped to the ends. A row jump near the last row should land
    /// on the last file rather than doing nothing.
    private func step(by offset: Int) {
        guard let current = runner.results.firstIndex(where: { $0.key == selected }),
              !runner.results.isEmpty else { return }
        let next = min(max(current + offset, 0), runner.results.count - 1)
        guard next != current else { return }
        selected = runner.results[next].key
    }

    private func confirm() {
        guard let item = selectedItem else { return }
        runner.confirm(item, as: draft)
        advance()
    }

    private func skip() {
        guard let item = selectedItem else { return }
        runner.skip(item)
        advance()
    }

    private func skipFolder() {
        guard let item = selectedItem else { return }
        runner.skipFolder(of: item)
        advance()
    }

    /// Carries out this one file straight away, then moves on like any other decision.
    private func applyNow() {
        guard let item = selectedItem, runner.decision(for: item) != .applied else { return }
        applyOne(item, draft)
        advance()
    }

    /// One menu, built for whichever file was right-clicked rather than the selected one,
    /// because a right-click on a row people have not selected still means that row.
    private func fileMenu(_ item: Item) -> FileContextMenu {
        FileContextMenu(
            item: item,
            confirm: {
                selected = item.key
                runner.confirm(item, as: item.destinationName)
                advance()
            },
            identify: {
                selected = item.key
                Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
            },
            moveTo: {
                selected = item.key
                choosingMoveTarget = true
            },
            trash: { runner.markForDeletion(item) },
            skip: { runner.skip(item) },
            convert: {
                selected = item.key
                converting.clear()
                showingMarkdown = true
            },
            tags: tagIndex.tags(for: item),
            availableTags: tagIndex.everyTag,
            tagsAvailable: tagIndex.isAvailable,
            onAddTag: { name in Task { await tagIndex.add(name, to: item) } },
            onRemoveTag: { name in Task { await tagIndex.remove(name, from: item) } },
            onNewTag: {
                newTagName = ""
                taggingItem = item
            }
        )
    }

    /// The one description of what tagging this file means, handed to every surface that
    /// offers it, so the menu, the card and the Details panel cannot drift apart.
    private func tagActions(for item: Item) -> TagActions {
        TagActions(
            tags: tagIndex.tags(for: item),
            available: tagIndex.everyTag,
            isAvailable: tagIndex.isAvailable,
            add: { name in Task { await tagIndex.add(name, to: item) } },
            remove: { name in Task { await tagIndex.remove(name, from: item) } },
            new: {
                newTagName = ""
                taggingItem = item
            }
        )
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealInFinder() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.currentURL])
    }

    private func openInViewer() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.open(item.currentURL)
    }

    /// Copies this file's BibTeX entry. When the entry is short of what its type wants and
    /// a key is configured, the model is asked first, so one action produces a citation
    /// worth pasting rather than a stub.
    private func copyCitation() {
        guard let item = selectedItem else { return }
        Task {
            runner.ensureBib()
            if let entry = runner.bibByItem[item.key], !entry.isComplete,
               aiReady, runner.ai.guesses[item.key] == nil {
                await runner.identify(item, client: aiClient, passwords: passwords, rules: rules)
                runner.ensureBib()
            }
            guard let entry = runner.bibByItem[item.key] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bibtexBlock(entry, style: bibStyle) + "\n", forType: .string)
            runner.note(.edited, subject: item.relativePath, detail: "citation copied")
        }
    }

    private func markDeleted() {
        guard let item = selectedItem else { return }
        runner.markForDeletion(item)
        advance()
    }

    /// After a decision, jump to the next file still waiting. When none are left the
    /// selection stays put so the last thing decided is still on screen.
    private func advance() {
        if let next = runner.nextPending() { selected = next.key }
        loadDraft()
    }

    @ViewBuilder
    private var browser: some View {
        switch mode {
        case .catalogue: catalogue
        case .list: list
        case .bibliography: bibliography
        case .duplicates: duplicatesView
        }
    }

    /// The same tree, showing what each file will contribute to the .bib. Selection is
    /// shared with the other two views, so the preview on the right keeps up and an
    /// entry can be checked against the page it came from.
    private var bibliography: some View {
        VStack(spacing: 0) {
            bibBar
            Divider()
            // Side by side where there is room. The entries and the file they generate are
            // the same thing seen two ways, and answering "is this entry right" by
            // flipping a switch and losing the other half is the slow way to do it. Below
            // 900 points there is not room for both, and the switch decides.
            GeometryReader { geometry in
                if geometry.size.width >= 900 {
                    HStack(spacing: 0) {
                        bibEntryList
                            .frame(width: max(380, geometry.size.width * 0.42))
                        Divider()
                        BibFileView(entries: runner.bib, order: $bibOrder,
                                    completeOnly: $bibCompleteOnly, style: bibStyle)
                            .frame(maxWidth: .infinity)
                    }
                } else if bibShowsFile {
                    BibFileView(entries: runner.bib, order: $bibOrder,
                                completeOnly: $bibCompleteOnly, style: bibStyle)
                } else {
                    bibEntryList
                }
            }
        }
        .onAppear {
            runner.bibType = bibType
            runner.ensureBib()
        }
        .onChange(of: runner.revision) { _, _ in runner.ensureBib() }
        .onChange(of: bibType) { _, new in
            runner.bibType = new
            runner.ensureBib()
        }
    }

    private var bibEntryList: some View {
        Group {
            ScrollViewReader { scroll in
                List(selection: $selected) {
                    ForEach(runner.tree) { node in
                        BibNodeView(node: node, expanded: $expanded, runner: runner)
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .onChange(of: selected) { _, new in
                    guard let new else { return }
                    expanded.formUnion(runner.ancestors(of: new))
                    withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    /// Duplicates get their own view rather than a badge, because deciding between two
    /// copies means seeing them next to each other and next to the page.
    private var duplicatesView: some View {
        Group {
            if runner.findingDuplicates {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Comparing \(runner.results.count) files").font(.headline)
                    Text("Hashing what shares a size, then reading opening pages")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runner.duplicates.isEmpty {
                ContentUnavailableView {
                    Label(runner.duplicatesChecked ? "No duplicates" : "Not compared yet",
                          systemImage: runner.duplicatesChecked ? "checkmark.seal" : "doc.on.doc")
                } description: {
                    Text(runner.duplicatesChecked
                         ? "Every file here is its own book."
                         : "Compare the \(runner.results.count) files by content and by name.")
                } actions: {
                    if !runner.duplicatesChecked {
                        Button("Find duplicates") { runner.findDuplicates(passwords: passwords) }
                .tip("Compare by bytes, by opening pages, and by name", key: "⌘D")
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    duplicatesBar
                    Divider()
                    List(selection: $selected) {
                        ForEach(runner.duplicates) { group in
                            DuplicateSection(group: group, runner: runner)
                        }
                    }
                    .listStyle(.inset)
                    .focused($listFocused)
                }
            }
        }
    }

    private var duplicatesBar: some View {
        let identical = runner.duplicates.filter { $0.kind == .identical }.count
        let sameText = runner.duplicates.filter { $0.kind == .sameText }.count
        let reclaimable = runner.duplicates.reduce(0) { $0 + $1.reclaimable }
        return HStack(spacing: 10) {
            Text("\(identical) identical, \(sameText) same pages, "
                 + "\(runner.duplicates.count - identical - sameText) by name")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(reclaimable), countStyle: .file)
                 + " in spare copies")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Recheck") { runner.findDuplicates(passwords: passwords) }
                .controlSize(.small)
                .tip("Compare again, after changes", key: "⌘D")
            Button("Trash \(runner.identicalExtras) identical spares") {
                runner.markIdenticalExtras()
                ensureSelection()
            }
            .controlSize(.small)
            .tip("Byte-identical groups only; name matches are left alone")
            .tint(Ink.red)
            .disabled(runner.identicalExtras == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var bibDocument: String {
        bibtexDocument(runner.bib, includeIncomplete: !bibCompleteOnly, order: bibOrder)
    }

    private var bibBar: some View {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
            // Counted the way the bibliography itself counts: an entry kept with its
            // document is judged by its own text, not by the guess it replaced.
            let incomplete = runner.bib.filter {
                !bibGaps($0, kept: kept, standard: bibStandard).isEmpty
            }.count
            Text("\(runner.bib.count) entries").font(.callout).foregroundStyle(.secondary)
            if incomplete > 0 {
                Label("\(incomplete) incomplete", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Ink.amber)
                    .help("Ask AI on those files to fill in author and year")
            }
            Spacer()
            Picker("", selection: $bibShowsFile) {
                Text("Entries").tag(false)
                Text("File").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tip("Browse the entries, or read the generated file")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
      .fixedSize(horizontal: false, vertical: true)
      .background(.bar)
    }

    /// A shelf of covers. `LazyVGrid` only builds what is on screen, and the cover store
    /// only renders what is built, so the cost follows the window and not the collection.
    ///
    /// The column count is computed here rather than left to `.adaptive`, because the
    /// arrow keys need to know it: in a grid, up and down mean a row, not a neighbour.
    private var catalogue: some View {
        GeometryReader { geometry in
            let count = catalogueColumns(for: geometry.size.width)
            catalogueGrid(columns: count)
                .onAppear { gridColumns = count }
                .onChange(of: count) { _, new in gridColumns = new }
        }
    }

    private func catalogueColumns(for width: CGFloat) -> Int {
        let spacing: CGFloat = 18
        let ideal: CGFloat = 168
        return max(1, Int((width - spacing + spacing) / (ideal + spacing)))
    }

    private func catalogueGrid(columns: Int) -> some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: 18), count: columns)
        let keys = visibleKeys
        let shown = keys.map { visible in runner.results.filter { visible.contains($0.key) } } ?? runner.results
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: layout, alignment: .leading, spacing: 18) {
                    ForEach(shown) { item in
                        CoverCard(
                            item: item,
                            decision: runner.decision(for: item),
                            duplicate: runner.duplicateKind[item.key],
                            passwords: passwords,
                            covers: covers,
                            isSelected: selected == item.key,
                            tags: tagIndex.tags(for: item)
                        )
                        .id(item.key)
                        .onTapGesture(count: 2) { openReader(item.key) }
                        .onTapGesture { selected = item.key }
                    }
                }
                .padding(18)
            }
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Two panes with a divider the user owns. `HSplitView` renegotiates its own widths
    /// whenever its children change, which is why the inspector kept jumping; here the
    /// width only ever changes because someone dragged it, and it is remembered.
    ///
    /// Which two panes depends on what the middle of the window is for. Deciding a name
    /// and reading a book are both about one document, so the page is there; a shelf, a
    /// bibliography and a list of duplicate groups are about a collection, and the page
    /// that used to sit beside them was half a window given to a file nobody had opened.
    private var split: some View {
        GeometryReader { geometry in
            if showsPage {
                pageSplit(available: geometry.size.width)
            } else {
                panelSplit(available: geometry.size.width)
            }
        }
    }

    /// Browser, divider, document. The outline and the inspector panel both fold inside
    /// the document region rather than widening the window (see `ReviewInspector`).
    private func pageSplit(available: CGFloat) -> some View {
        // The contents rail is nested inside the document region, not a sibling here, so
        // it only needs to widen that region's own floor, not the outer reservation
        // `inspectorMaximum` makes for the browser.
        let contentsOpen = contentsShown && !annotator.contents.isEmpty
        let minimum = SplitLayout.inspectorMinimum(contentsShown: contentsOpen)
        let maximum = SplitLayout.inspectorMaximum(
            available: available, contentsShown: contentsOpen)
        // Not `min(max(inspectorWidth, minimum), maximum)`: that returns the floor even
        // when the window is narrower than the floor, and the pane is then drawn at a
        // width the window cannot show.
        let width = SplitLayout.inspectorWidth(
            preferred: inspectorWidth, available: available, contentsShown: contentsOpen)
        return HStack(spacing: 0) {
            if showsBrowser {
                browser.frame(maxWidth: .infinity, maxHeight: .infinity).region(.document)
                divider(width: width, minimum: minimum, maximum: maximum)
            }
            documentRegion(paneWidth: showsBrowser ? width : available)
                .frame(width: showsBrowser ? width : nil)
                .frame(maxWidth: showsBrowser ? nil : .infinity, maxHeight: .infinity)
        }
    }

    /// Browser and inspector, with nothing between them. Under
    /// `SplitLayout.inspectorOverlaysBelow` the panel is drawn over the browser instead of
    /// taking room from it, which is the same bargain the page's own panel makes.
    private func panelSplit(available: CGFloat) -> some View {
        let overlays = SplitLayout.inspectorOverlays(paneWidth: available)
        // Two copies beside each other need more than a panel's width; a panel of
        // metadata does not.
        let floor = selectedDuplicateGroup == nil ? Metric.inspectorMin : 420
        let maximum = max(floor, available - SplitLayout.contentFloor)
        let width = min(max(inspectorWidth, floor), maximum)
        return HStack(spacing: 0) {
            browser.frame(maxWidth: .infinity, maxHeight: .infinity).region(.document)
            if !inspectorCollapsed && !overlays {
                divider(width: width, minimum: floor, maximum: maximum)
                documentRegion(paneWidth: width)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
            }
        }
        .overlay(alignment: .trailing) {
            if !inspectorCollapsed && overlays {
                floatingPanel(width: SplitLayout.panelWidth(paneWidth: available))
            }
        }
    }

    /// The inspector over the browser, on a window with no room to put it beside one.
    private func floatingPanel(width: CGFloat) -> some View {
        documentRegion(paneWidth: width)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .leading) { Divider() }
            .shadow(color: .black.opacity(0.18), radius: 10, x: -3)
    }

    private func divider(width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
        Divider()
            .background(.separator)
            .frame(width: 1)
            .overlay {
                // A 10pt grab strip: a 1pt divider is not a target anyone can hit.
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                // A drag's translation is measured from where it started,
                                // so it has to be added to the width it started at. Adding
                                // it to the live width fed each frame's result back into
                                // the next one, which is why the divider accelerated away
                                // and landed at widths nobody asked for.
                                let anchor = dragAnchor ?? width
                                if dragAnchor == nil { dragAnchor = anchor }
                                inspectorWidth = min(max(anchor - value.translation.width,
                                                         minimum), maximum)
                            }
                            .onEnded { _ in dragAnchor = nil }
                    )
            }
    }

    private var list: some View {
        ScrollViewReader { scroll in
            List(selection: $selected) {
                ForEach(runner.tree) { node in
                    NodeView(node: node, expanded: $expanded, facts: RowFacts(runner: runner),
                             menu: fileMenu, tags: tagIndex.tags, openFolder: openFolder,
                             visible: visibleKeys)
                }
            }
            .listStyle(.inset)
            // An NSTableView draws its selection grey unless it is the first responder,
            // which is why the highlight looked inert while the keys were driving it.
            .focused($listFocused)
            .onChange(of: selected) { _, new in
                guard let new else { return }
                expanded.formUnion(runner.ancestors(of: new))
                withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
            }
        }
    }

    // MARK: Review inspector

    @ViewBuilder
    /// The group the selected file belongs to, if it is one of a set of copies.
    private var selectedDuplicateGroup: DuplicateGroup? {
        guard mode == .duplicates, let selected else { return nil }
        return runner.duplicates.first { group in
            group.items.contains { $0.key == selected }
        }
    }

    /// What the trailing region holds: two copies to choose between, one document with
    /// its page and panel, or the panel alone.
    private func documentRegion(paneWidth: CGFloat) -> some View {
        Group {
        // Choosing between two copies means seeing them beside each other. In the view
        // whose whole job is that decision, this is what the pane should hold.
        if let group = selectedDuplicateGroup {
            DuplicateCompare(
                group: group,
                keep: { runner.keep($0, inGroup: group.id) },
                trashExtras: { runner.trashExtras(of: group.id) }
            )
        } else if let item = readerItem ?? selectedItem {
            ReviewInspector(
                showsPage: showsPage,
                paneWidth: paneWidth,
                item: item,
                runner: runner,
                passwords: passwords,
                draft: $draft,
                editing: $editingName,
                confirm: confirm,
                skip: skip,
                skipFolder: skipFolder,
                applyNow: applyNow,
                identify: identifySelected,
                copyCitation: copyCitation,
                improveCitation: { system, user in
                    try await aiClient.ask(system: system, user: user, feature: .bibtex)
                },
                autoIdentify: $autoIdentify,
                reveal: revealInFinder,
                openExternally: openInViewer,
                moveTo: { choosingMoveTarget = true },
                aiReady: aiReady,
                markDeleted: markDeleted,
                reopen: reopenSelected,
                read: { openReader(item.key) },
                leaveReader: reader == nil ? nil : closeReader,
                reset: { draft = item.destinationName },
                leaveField: { editingName = false; listFocused = true },
                excerpt: runner.excerpt(for: item),
                reading: reading,
                tags: tagActions(for: item),
                annotator: annotator,
                palette: palette
            )
        } else if runner.lastRunWasDry && !runner.results.isEmpty && runner.pendingCount == 0 {
            ContentUnavailableView(
                "Every file reviewed",
                systemImage: "checkmark.seal",
                description: Text("Apply is unlocked. Pick a row to look at it again.")
            )
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "sidebar.right",
                description: Text("Pick a file to see it.")
            )
        }
        }
    }

    /// Fills in a selection only when there is not already a good one. Whatever file you
    /// are on stays put: it is only moved by a decision, by the arrow and J/K keys, or by
    /// a new run that no longer contains it.
    private func ensureSelection() {
        if let selected, runner.results.contains(where: { $0.key == selected }) {
            loadDraft()
            return
        }
        selected = runner.nextPending()?.key
        loadDraft()
    }

    // MARK: Header

    /// One row, and only what says what is on screen: where you are, what is filtering,
    /// how much of the collection that leaves, and the order.
    ///
    /// It was two rows that scrolled sideways and changed shape while work was running,
    /// because it was also where progress, decision counts, batch actions and the state
    /// label lived. Progress and counts are in the status bar; the actions are in the
    /// toolbar, where an action belongs.
    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    if shelves.current != .all {
                        chip(shelves.current.title, icon: shelves.current.icon) {
                            shelves.current = .all
                        }
                        .tip(shelves.current.explanation)
                    }
                    if let folderScope {
                        chip(folderScope.lastPathComponent, icon: "folder.fill") {
                            self.folderScope = nil
                        }
                        .tip("Showing only this folder's files")
                    }
                    ForEach(Query.chips(query), id: \.self) { piece in
                        chip(piece, icon: nil) { removeChip(piece) }
                    }
                    if mode == .list {
                        Toggle("Only undecided", isOn: $onlyUndecided)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .tip("Hide everything already confirmed, skipped or trashed")
                    }
                    ForEach(runner.statusCounts, id: \.0) { status, count in
                        StatusPill(status: status, count: count)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 6)

            Text(shownLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(visibleKeys?.isEmpty == true ? Ink.amber : .secondary)
                .fixedSize()

            sortMenu
        }
        .padding(.horizontal, 14)
        .frame(height: Metric.filterBar)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// What the window is looking at, in the title where the platform puts it.
    ///
    /// It said "PDF Hammer" on every screen, which is the one thing a person looking at
    /// the window already knows.
    private var placeTitle: String {
        if let item = readerItem ?? (reading ? selectedItem : nil) {
            return runner.ai.guesses[item.key]?.title ?? item.destinationName
        }
        switch mode {
        case .bibliography: return "Bibliography"
        case .duplicates: return "Duplicates"
        default:
            return folderScope?.lastPathComponent ?? shelves.current.title
        }
    }

    /// What is in the place, counted. The transient part of this -- what is running, what
    /// has been decided -- is in the status bar and deliberately not here.
    private var placeSubtitle: String {
        if let item = readerItem ?? (reading ? selectedItem : nil) {
            let guess = runner.ai.guesses[item.key]
            let pages = item.pageCount.map { "\($0) pages" }
            return [guess?.author, guess?.year, pages]
                .compactMap { $0 }.joined(separator: " · ")
        }
        switch mode {
        case .duplicates:
            let files = runner.duplicates.reduce(0) { $0 + $1.items.count }
            return "\(runner.duplicates.count) group\(runner.duplicates.count == 1 ? "" : "s") · \(files) files"
        case .bibliography:
            return "\(runner.bib.count) entr\(runner.bib.count == 1 ? "y" : "ies")"
        default:
            let shown = visibleKeys?.count ?? runner.results.count
            return "\(shown) shown · \(sourceCount) source\(sourceCount == 1 ? "" : "s")"
        }
    }

    /// How much of the collection is on screen. Always M of N, so the number never has to
    /// be read twice to find out whether anything is filtering.
    private var shownLabel: String {
        let shown = visibleKeys?.count ?? runner.results.count
        return "\(shown) of \(runner.results.count) shown"
    }

    private func removeChip(_ piece: String) {
        query = Query.removing(piece, from: query)
        runner.search(strippingTagTerms(query), passwords: passwords)
    }

    /// A filter, with the ✕ that takes it off. Nothing here is a state you cannot leave.
    private func chip(_ text: String, icon: String?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Metric.control))
        .foregroundStyle(Color.accentColor)
    }

    /// One control rather than a picker and a direction button beside it: the order and
    /// which way it runs are one decision.
    private var sortMenu: some View {
        Menu {
            ForEach(ItemSort.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    if order == sortOrder { Label(order.label, systemImage: "checkmark") }
                    else { Text(order.label) }
                }
            }
            Divider()
            Toggle("Largest or newest first", isOn: $sortDescending)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                Text(sortOrder.label)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tip("Reorders within each folder, and across the catalogue")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { runner.search(strippingTagTerms(query), passwords: passwords) }
                .onChange(of: query) { _, new in
                    // Metadata is instant; a text query waits for Return so a shelf is
                    // not read from end to end on every keystroke.
                    if new.isEmpty || !Query(new).needsText {
                        runner.search(strippingTagTerms(new), passwords: passwords)
                    }
                }
            if runner.searching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button {
                    query = ""
                    runner.search("", passwords: passwords)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .tip("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 240)
        .tip("Search names, or use folder: size> text: …", key: "/")
    }

    @ViewBuilder
    private var duplicateControls: some View {
        if runner.findingDuplicates {
            ProgressView().controlSize(.small)
            Text("Comparing…").font(.callout).foregroundStyle(.secondary)
        } else if runner.duplicates.isEmpty {
            Button("Find duplicates") { runner.findDuplicates() }
                .controlSize(.small)
        } else {
            let identical = runner.duplicates.filter { $0.kind == .identical }.count
            let sameText = runner.duplicates.filter { $0.kind == .sameText }.count
            let likely = runner.duplicates.count - identical - sameText
            Text("\(identical) identical, \(sameText) same pages, \(likely) by name")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Trash \(runner.identicalExtras) spare copies") {
                runner.markIdenticalExtras()
                ensureSelection()
            }
            .controlSize(.small)
            .disabled(runner.identicalExtras == 0)
        }
    }

    private var busyState: some View {
        BusyOverlay(activity: runner.activity, scanning: runner.phase == .scanning)
    }

    @ViewBuilder
    private var emptyState: some View {
        // Two different empty screens. "No sources" is the first thing a person ever sees
        // and has to explain what the app is for; "sources but nothing scanned" is a
        // button away from a shelf and needs no introduction.
        if hasSources {
            ContentUnavailableView {
                Label("Ready to run", systemImage: "wand.and.sparkles")
            } description: {
                Text("\(sourceCount) source\(sourceCount == 1 ? "" : "s") queued. Plan first, then apply.")
            } actions: {
                Button("Plan", action: preview).buttonStyle(.borderedProminent)
            }
        } else {
            FirstRun(chooseFiles: chooseFiles)
        }
    }
}

// MARK: - Tags

/// Bridges the catalogue's items to the library's tags.
///
/// A file's identity in the library is its document id, not its path, so showing a tag
/// on a row means resolving each item to a document first. `tagsByDocument()` already
/// gives every tag in one query; the id lookups below are the only per-item cost, and
/// they are done once per item, kept here, rather than once per row per repaint.
@MainActor
final class CatalogueTags: ObservableObject {
    private let library: Library?
    /// Document id -> tag names.
    @Published private(set) var byDocument: [String: [String]] = [:]
    /// Item key -> document id, resolved lazily as items are seen. A file the library has
    /// never heard of (just noticed, or seen while the store could not open) has no entry
    /// here, which is the true state: it cannot be tagged until it does.
    @Published private(set) var documentID: [String: String] = [:]
    /// Every tag name in use anywhere, offered when adding one so nobody has to retype or
    /// misspell a tag that already exists.
    @Published private(set) var everyTag: [String] = []
    /// Bumped whenever the tag tables change, so a view filtering by tag can tell in one
    /// comparison whether its last answer still holds.
    @Published private(set) var revision = 0

    init(library: Library? = Library.shared) {
        self.library = library
    }

    /// False only when the store itself could not be opened. A file simply not indexed
    /// yet is a different, recoverable state (see `add`), not this one.
    var isAvailable: Bool { library != nil }

    func tags(for item: Item) -> [String] {
        documentID[item.key].flatMap { byDocument[$0] } ?? []
    }

    /// Loads the tag table and resolves any items not yet mapped to a document. Safe to
    /// call again after every change to the result set: already-resolved items are
    /// skipped, so this only ever does work for what is new.
    func refresh(items: [Item]) async {
        guard let library else { return }
        if let all = try? await library.tagsByDocument() { byDocument = all }
        if let counts = try? await library.tagCounts() { everyTag = counts.map(\.name) }
        defer { revision &+= 1 }

        let unresolved = items.filter { documentID[$0.key] == nil }
        guard !unresolved.isEmpty else { return }
        // One query for the whole shelf. This used to ask per file, which on a thousand
        // files was a thousand round trips through the library actor and two statements
        // each, all to end up with the ids.
        guard let byPath = try? await library.documentIDsByPath() else { return }
        for item in unresolved {
            // The plain path first: paths are recorded resolved, but resolving one is a
            // filesystem call and almost no shelf is reached through a link.
            if let id = byPath[item.currentURL.path]
                ?? byPath[item.currentURL.resolvingSymlinksInPath().path] {
                documentID[item.key] = id
            }
        }
    }

    /// Adds a tag, indexing the file first if the library has not seen it yet: a file a
    /// run only just noticed is not a document until something says so, and making that
    /// wait for the next full sync (`Runner.syncLibrary`, run after preview or apply)
    /// would turn "add a tag" into "add a tag, eventually." Everything indexed here is
    /// exactly what that sync would have written anyway, just sooner.
    @discardableResult
    func add(_ name: String, to item: Item) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let library, !trimmed.isEmpty else { return false }
        let id: String
        if let existing = documentID[item.key] {
            id = existing
        } else {
            let path = item.currentURL.resolvingSymlinksInPath().path
            guard let record = try? await library.indexDocument(
                path: path, contentHash: nil, byteCount: item.byteCount, pageCount: item.pageCount,
                title: item.documentInfo["Title"], author: item.documentInfo["Author"],
                documentInfo: item.documentInfo)
            else { return false }
            id = record.id
            documentID[item.key] = id
        }
        guard (try? await library.addTag(trimmed, toDocument: id)) != nil else { return false }
        if !(byDocument[id]?.contains(trimmed) ?? false) {
            byDocument[id, default: []].append(trimmed)
            byDocument[id]?.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        if !everyTag.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            everyTag.append(trimmed)
            everyTag.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return true
    }

    func remove(_ name: String, from item: Item) async {
        guard let library, let id = documentID[item.key] else { return }
        try? await library.removeTag(name, fromDocument: id)
        byDocument[id]?.removeAll { $0 == name }
    }
}

/// A brand new tag's name, typed once. Mirrors `Projects.swift`'s `NewProjectSheet`: a
/// context menu cannot host a text field reliably, so naming something new is always a
/// small sheet like this one, never the menu itself.
private struct NewTagSheet: View {
    @Binding var name: String
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tag").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onAdd(name) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { onAdd(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

extension Notification.Name {
    /// Posted by anything that wants the catalogue scoped to one folder on disk. The file
    /// explorer `ContentView.swift` is growing publishes this when a folder is chosen
    /// there; `Catalogue.swift`'s own right-click on a folder handles itself locally but
    /// answers to the same notification, so either side can drive the other.
    ///
    /// `userInfo["path"]` is the folder's absolute filesystem path as a `String` (not a
    /// `URL`, which does not cross `NotificationCenter`'s `Sendable` boundary without
    /// extra ceremony). A path outside anything currently loaded is not an error: the
    /// catalogue simply ends up showing zero files, same as any other search with no
    /// matches.
    static let openFolderInCatalogue = Notification.Name("PDFHammer.openFolderInCatalogue")
    /// Posted with the tag's name in `userInfo["tag"]` by the sidebar's Tags panel.
    static let showTagInCatalogue = Notification.Name("PDFHammer.showTagInCatalogue")
    /// Posted with a project's `Int64` id in `userInfo["id"]` by the palette, which can
    /// reach a project the sidebar would have to be scrolled to.
    static let openProject = Notification.Name("PDFHammer.openProject")
}

// MARK: - Review inspector

/// What a row needs to know about the file it draws, without being handed the object
/// that also knows about the scan, the model, the log and the spend.
@MainActor
struct RowFacts {
    var item: (String) -> Item?
    var decision: (Item) -> Decision?
    var duplicate: (String) -> DuplicateGroup.Kind?

    init(runner: Runner) {
        item = { [weak runner] key in runner?.item(key) }
        decision = { [weak runner] item in runner?.decision(for: item) }
        duplicate = { [weak runner] key in runner?.duplicateKind[key] }
    }
}

struct NodeView: View {
    let node: Node
    @Binding var expanded: Set<String>
    /// Three lookups, not an observable. A row subscribed to `Runner` was redrawn by a
    /// scan tick, a line in the log, and a model request about some other file -- which
    /// is the whole of the redesign's second finding.
    let facts: RowFacts
    var menu: (Item) -> FileContextMenu = { item in
        FileContextMenu(item: item, confirm: {}, identify: {}, moveTo: {}, trash: {},
                        skip: {}, convert: {})
    }
    /// The library's tags for one item, kept outside this view so a tag edit does not
    /// have to rebuild the whole tree, only repaint the rows that read it.
    var tags: (Item) -> [String] = { _ in [] }
    /// Answers a folder's own right-click. Passed down rather than posted as a
    /// notification, since the caller (`ResultsPane`) already owns the state a scope
    /// change has to land in.
    var openFolder: (URL) -> Void = { _ in }
    /// Nil means no filter. A folder with nothing visible under it disappears too.
    var visible: Set<String>?
    /// This node's own path in `folder:` terms, i.e. relative to whatever root it came
    /// from: empty at the top level, since a root's own name is never part of an item's
    /// `relativePath` (see `Item.relativePath` in `Hammer.swift`).
    var relativeFolder: String = ""

    private var isHidden: Bool {
        guard let visible else { return false }
        if let key = node.itemKey { return !visible.contains(key) }
        return !anyVisible(node, visible)
    }

    private func anyVisible(_ node: Node, _ visible: Set<String>) -> Bool {
        if let key = node.itemKey { return visible.contains(key) }
        return (node.children ?? []).contains { anyVisible($0, visible) }
    }

    var body: some View {
        if isHidden {
            EmptyView()
        } else if let key = node.itemKey, let item = facts.item(key) {
            ResultRow(item: item, decision: facts.decision(item),
                      duplicate: facts.duplicate(item.key), tags: tags(item))
                .tag(key)
                .id(key)
                .contextMenu { menu(item) }
                // A real file drag: Finder and anything else that takes one gets a copy.
                .onDrag { NSItemProvider(contentsOf: item.currentURL) ?? NSItemProvider() }
        } else {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    NodeView(node: child, expanded: $expanded, facts: facts,
                             menu: menu, tags: tags, openFolder: openFolder, visible: visible,
                             relativeFolder: relativeFolder.isEmpty ? child.name : "\(relativeFolder)/\(child.name)")
                }
            } label: {
                Label {
                    Text(node.name).fontWeight(.medium)
                    Text("\(count(node))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                }
                // The whole row opens the folder, not just the chevron.
                .contentShape(Rectangle())
                .onTapGesture { expansion.wrappedValue.toggle() }
            }
            .contextMenu {
                Button("Open in Catalogue") {
                    if let item = firstDescendantItem(of: node) {
                        openFolder(item.root.appendingPathComponent(relativeFolder))
                    }
                }
            }
        }
    }

    /// One file under this folder, used to recover the folder's own absolute path: a
    /// `Node` only ever stores names, and every folder here has at least one file under
    /// it (see `buildTree`), so there is always one to ask.
    private func firstDescendantItem(of node: Node) -> Item? {
        if let key = node.itemKey { return facts.item(key) }
        for child in node.children ?? [] {
            if let found = firstDescendantItem(of: child) { return found }
        }
        return nil
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { open in
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
    }

    private func count(_ node: Node) -> Int {
        guard let children = node.children else { return 1 }
        return children.reduce(0) { $0 + count($1) }
    }
}

struct ResultRow: View {
    let item: Item
    let decision: Decision?
    var duplicate: DuplicateGroup.Kind?
    var tags: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            reviewMark
                .frame(width: 15)
                .padding(.top, 2)
            StatusPill(status: item.status, count: nil)
                .frame(width: 108, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(decision == .deleted ? item.sourceName : shownName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(decision == .deleted)
                stats
                if decision == .deleted {
                    Label("will be moved to the Trash", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(Ink.red)
                } else if shownName != item.sourceName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(item.sourceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("already normalized")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !item.message.isEmpty {
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? .red : .orange)
                }
                if !tags.isEmpty {
                    tagChips
                }
            }
            Spacer(minLength: 0)
            if let duplicate {
                Image(systemName: duplicateIcon(duplicate))
                    .foregroundStyle(duplicateColour(duplicate))
                    .help(duplicateExplanation(duplicate))
            }
        }
        .padding(.vertical, 3)
        .opacity(decision == .skipped ? 0.45 : 1)
    }

    private var shownName: String {
        if case .confirmed(let name) = decision { return name }
        return item.destinationName
    }

    /// Size, length and age, which is what tells two similar-looking files apart.
    @ViewBuilder
    private var stats: some View {
        let parts = [
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            item.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" },
            item.modifiedDate.map { $0.formatted(date: .abbreviated, time: .omitted) },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    /// What this file is tagged, read from the tag index rather than a query of its own
    /// (see `CatalogueTags`), so a row full of files costs one lookup each, not one
    /// round trip to the library each.
    private var tagChips: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
        }
    }

    @ViewBuilder
    private var reviewMark: some View {
        markGlyph.tip(decision?.explanation ?? undecidedExplanation)
    }

    @ViewBuilder
    private var markGlyph: some View {
        switch decision {
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Ink.green)
        case .applied:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Ink.green)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
        case .deleted:
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(Ink.red)
        case .moveTo:
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(Ink.purple)
        case nil:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}

/// One book on the shelf: cover, name, and the two badges that matter (what you decided,
/// and whether another copy of it exists).
struct CoverCard: View {
    let item: Item
    let decision: Decision?
    let duplicate: DuplicateGroup.Kind?
    let passwords: [String]
    @ObservedObject var covers: Covers
    let isSelected: Bool
    /// What this file is tagged with. Shown on the card so a shelf can be read by tag at a
    /// glance rather than one right-click at a time.
    var tags: [String] = []
    /// This card's own cover. Held here rather than read out of a shared counter, so a
    /// render landing anywhere else on the shelf does not redraw this card.
    @State private var cover: NSImage?

    /// How tall to rasterise, in pixels: the size a card actually draws at, doubled for a
    /// retina display. It used to be a flat 320 whatever the card measured, which on a
    /// dense shelf is a lot of pixels rendered to be thrown away.
    static let rasterHeight = Metric.coverHeight(forWidth: Metric.coverWidth) * 2

    private var name: String {
        if case .confirmed(let confirmed) = decision { return confirmed }
        return item.destinationName
    }

    /// What the book calls itself, or the filename without its extension when it says
    /// nothing. Never the model's guess: that guess is already in the name below, and a
    /// card claiming a title the file does not carry is a card that lies.
    private var bookTitle: String {
        let stated = item.documentInfo["Title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stated, !stated.isEmpty { return stated }
        return (name as NSString).deletingPathExtension
    }

    private var physical: String {
        [
            item.pageCount.map { "\($0) pp" },
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary.opacity(0.5))
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                } else {
                    Image(systemName: item.status == .locked ? "lock.fill" : "book.closed")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                }
            }
            // As wide as its cell and as tall as a book of that width. It was 168 points
            // whatever the width, which is why a tall book sat in a letterbox and a wide
            // one was cropped: the band was a constant and a book is not.
            .frame(maxWidth: .infinity)
            .aspectRatio(1 / Metric.coverAspect, contentMode: .fit)
            .overlay(alignment: .topTrailing) { badges }
            .task(id: "\(item.key)#\(covers.generation)") {
                if let hit = covers.cached(item) { cover = hit; return }
                cover = nil
                cover = await covers.cover(for: item, passwords: passwords,
                                           height: CoverCard.rasterHeight)
            }

            // A book says its own name in its own voice, with the filename underneath
            // in mono where a character's identity matters. Read off the document rather
            // than guessed: the card must not disagree with the file it draws.
            Text(bookTitle)
                .font(Face.page)
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(decision == .deleted ? .secondary : .primary)
                .strikethrough(decision == .deleted)

            if let author = item.documentInfo["Author"], !author.isEmpty {
                Text(author)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(name)
                .font(Face.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)

            Text(physical)
                .font(Face.micro.monospacedDigit())
                .foregroundStyle(.tertiary)

            if !tags.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.55), in: Capsule())
                    }
                }
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .opacity(decision == .skipped ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if let duplicate {
                Image(systemName: duplicateIcon(duplicate))
                    .foregroundStyle(duplicateColour(duplicate))
                    .help(duplicateExplanation(duplicate))
            }
            switch decision {
            case .confirmed: Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Ink.green)
            case .applied: Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Ink.green)
            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            case .deleted: Image(systemName: "trash.circle.fill")
                .foregroundStyle(Ink.red)
            case .moveTo: Image(systemName: "arrow.right.circle.fill").foregroundStyle(Ink.purple)
            case nil: EmptyView()
            }
        }
        .font(.body)
        .padding(5)
    }
}

struct StatusPill: View {
    let status: Status
    var count: Int?

    var body: some View {
        Label {
            Text(count.map { "\($0) \(status.rawValue)" } ?? status.rawValue)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .fittedBackground(color.opacity(0.16), in: Capsule())
        .tip(status.explanation)
    }

    private var icon: String {
        switch status {
        case .decrypted: return "lock.open.fill"
        case .renamed: return "textformat"
        case .locked: return "lock.fill"
        case .encrypted: return "lock.rotation"
        case .trashed: return "trash.fill"
        case .moved: return "arrow.right.doc.on.clipboard"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// System greens and oranges sit around 2:1 on a light background, which is
    /// unreadable at caption size. These are darkened for light and lifted for dark.
    private var color: Color {
        switch status {
        case .decrypted: return Ink.green
        case .renamed:   return Ink.blue
        case .locked:    return Ink.amber
        case .encrypted: return Ink.blue
        case .trashed:   return Ink.grey
        case .moved:     return Ink.purple
        case .failed:    return Ink.red
        }
    }
}

// MARK: - Bibliography

/// One group of copies. The keeper is marked, every other copy offers to take its place,
/// and selecting any row shows it in the preview so two copies can be compared.
struct DuplicateSection: View {
    let group: DuplicateGroup
    @ObservedObject var runner: Runner

    var body: some View {
        Section {
            ForEach(group.items) { item in
                DuplicateRow(
                    item: item,
                    isKeeper: item.key == group.keeper.key,
                    decision: runner.decision(for: item),
                    keep: { runner.keep(item, inGroup: group.id) }
                )
                .tag(item.key)
                .id(item.key)
            }
        } header: {
            HStack(spacing: 8) {
                Label(duplicateLabel(group.kind), systemImage: duplicateIcon(group.kind))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(duplicateColour(group.kind))
                    .help(duplicateExplanation(group.kind))
                Text("\(group.items.count) copies")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(group.reclaimable), countStyle: .file)
                     + " spare")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Trash the other \(group.extras.count)") {
                    runner.trashExtras(of: group.id)
                }
                .controlSize(.small)
                .tip("Keeps the starred copy, trashes the rest of this group")
                .tint(Ink.red)
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

func duplicateLabel(_ kind: DuplicateGroup.Kind) -> String {
    switch kind {
    case .identical: return "Identical"
    case .sameText: return "Same pages"
    case .likely: return "Similar names"
    }
}

func duplicateIcon(_ kind: DuplicateGroup.Kind) -> String {
    switch kind {
    case .identical: return "doc.on.doc.fill"
    case .sameText: return "text.magnifyingglass"
    case .likely: return "doc.on.doc"
    }
}

func duplicateColour(_ kind: DuplicateGroup.Kind) -> Color {
    switch kind {
    case .identical: return Ink.red
    case .sameText: return Ink.purple
    case .likely: return Ink.amber
    }
}

func duplicateExplanation(_ kind: DuplicateGroup.Kind) -> String {
    switch kind {
    case .identical: return "Byte for byte the same file"
    case .sameText: return "Different bytes, but the opening pages read the same"
    case .likely: return "Only the names agree, which is a guess"
    }
}

struct DuplicateRow: View {
    let item: Item
    let isKeeper: Bool
    let decision: Decision?
    let keep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isKeeper ? "star.fill" : "circle")
                .foregroundStyle(isKeeper
                                 ? Ink.green
                                 : Color.secondary.opacity(0.5))
                .padding(.top, 2)
                .help(isKeeper ? "The copy to keep" : "A spare copy")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(decision == .deleted)
                Text(item.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount ?? 0), countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if decision == .deleted {
                Label("Trash", systemImage: "trash.fill")
                    .font(.caption)
                    .foregroundStyle(Ink.red)
            } else if !isKeeper {
                Button("Keep this one", action: keep)
                    .controlSize(.small)
                    .tip("Make this the copy the group keeps")
            }
        }
        .padding(.vertical, 3)
        .opacity(decision == .deleted ? 0.55 : 1)
    }
}

// MARK: - Sidebar rail


/// What a run is doing, while it does it.
///
/// A view of its own so the numbers that move several times a second are watched by
/// something the size of this box rather than by the pane that holds every row.
struct BusyOverlay: View {
    @ObservedObject var activity: Activity
    let scanning: Bool

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text(scanning ? "Looking for PDFs" : "Processing files")
                .font(.headline)
            Text(scanning
                 ? "\(activity.found) found so far"
                 : "\(activity.done) of \(activity.total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(activity.current)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 480)
                .opacity(activity.current.isEmpty ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter cache

/// Holds the last answer `visibleKeys` gave, keyed on everything that could change it.
///
/// Deliberately not an `ObservableObject` and deliberately a reference type held in
/// `@State`: it publishes nothing, which is what makes it safe to read and update from
/// inside `body`, and it survives the body passes that a value type would not.
final class VisibleFilter {
    struct Signature: Equatable {
        let results: Int
        let matching: Int
        let tags: Int
        let query: String
        let scope: URL?
        let undecidedOnly: Bool
        /// How many files have been decided. A decision changes what "only undecided"
        /// leaves on screen, and nothing else in this signature would notice.
        let decisions: Int
        let list: SmartList
        /// Bumped when the library's answer for a list changes -- a file tagged, a page
        /// turned -- which nothing else here would notice either.
        let lists: Int
    }

    private var signature: Signature?
    private var cached: Set<String>?

    func keys(matching new: Signature, compute: () -> Set<String>?) -> Set<String>? {
        if signature == new { return cached }
        let value = compute()
        signature = new
        cached = value
        return value
    }
}
