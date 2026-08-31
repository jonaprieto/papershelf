import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PaperShelfCore

struct ResultsPane: View {
    var runner: Runner
    var covers: Covers
    @Binding var expanded: Set<String>
    @Binding var selected: String?
    let sourceCount: Int
    let unavailableSourceCount: Int
    let previewIsCurrent: Bool
    let passwords: [String]
    let reading: Bool
    /// Reading mode belongs to the window, not to this pane, but the button belongs in
    /// this pane's toolbar group so the order reads views · search · actions · chrome.
    /// A setter rather than a toggle because the views in the same bar have to be able to
    /// leave the mode outright: see `choose(_:)`.
    var setReading: (Bool) -> Void = { _ in }
    let watching: Bool
    var palette: Palette
    /// The live page. Owned by the window rather than by this pane: the status bar sits
    /// outside it and says what is on the page -- how long the document is and how many
    /// marks are on it.
    var annotator: Annotator
    let rules: NameRules
    let chooseFiles: () -> Void
    let focusSidebar: () -> Void
    let handleSidebarKey: (UInt16) -> Bool
    let preview: () -> Void
    /// Reads the sources again, for ⌘R. Owned by the window: this pane knows what is on
    /// screen, not where it came from.
    let refresh: () -> Void
    let apply: () -> Void
    let applyOne: (Item, String) -> Void

    private var hasSources: Bool { sourceCount > 0 }


    @Bindable private var prefs = Prefs.shared
    private let kept: KeptBibtex = .shared
    /// The inspector's width when the current divider drag began. Nil when nothing is
    /// being dragged.
    @State private var dragAnchor: CGFloat?
    /// Hides everything already decided, so what is left is what is still asking for a
    /// decision. A filter like any other, and it says so in the filter bar.
    /// Kept in step with the grid so the arrow keys can move by a row.
    @State private var gridColumns = 1
    /// Whether the row now selected was clicked. A click needs no scrolling: the row is
    /// already under the pointer, and animating it to the middle of the pane pulls the
    /// list out from under the hand that clicked it. Only a selection moved some other way
    /// -- a key, a decision, a search landing somewhere else -- has to be scrolled to.
    @State private var pickedByPointer = false
    @State private var showingShortcuts = false
    @State private var converting = Converting()
    @State private var showingMarkdown = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var confirmingBatchAI = false
    /// How wide the document region is: the page and the inspector panel together.
    ///
    /// A new key, because the number means something else than it did. It used to be the
    /// width of a panel; the region it names now also holds the page, and the old 460
    /// left the page 140 points once the panel had taken its 320. The default is the
    /// design's own proportion — a page you can read a paragraph across, and the panel.
    /// How wide the inspector is where there is no page beside it — the shelf, the
    /// bibliography, the duplicates view. Its own preference, because the region it names
    /// holds one column of controls rather than a page and a column.
    /// The same two keys the inspector reads, so the toolbar's note button lands on the
    /// tab it names rather than on whichever one was last open.
    @State private var addingNote = false
    @State private var noteText = ""
    @State private var tagIndex = CatalogueTags()
    /// Which of the four library lists the shelf is showing, shared with the sidebar that
    /// sets it.
    private let shelves: Shelves = .shared
    private let regions: Regions = .shared
    /// Remembers the last filter result. The grid, the folder tree and the "N of M shown"
    /// label each need it, and each used to recompute it: three passes over the whole
    /// collection per render, and again on every tick of a window resize because the grid
    /// asks from inside a `GeometryReader`.
    @State private var filter = VisibleFilter()
    /// Remembers the shelf's own last answer -- the results narrowed to `visibleKeys` --
    /// keyed the same way `filter` is. `visibleKeys` being cached did not save the grid
    /// anything: it was still filtering the whole collection down to that set on every
    /// render, and again on every tick of a window resize.
    @State private var shownFilter = ShownFilter()
    /// The file a "New Tag…" prompt was opened for. Non-nil drives the sheet.
    @State private var taggingItem: Item?
    @State private var newTagName = ""
    /// Set by right-clicking a folder here, or by the file explorer publishing
    /// `.openFolderInCatalogue`: narrows what the catalogue shows to files under one
    /// folder, on top of whatever the search box is doing.
    @State private var folderScope: URL?
    /// How wide this pane is, so the toolbar can tell whether the four views fit as a row
    /// of icons.
    @State private var viewPaneWidth: CGFloat = SplitLayout.windowFloorWidth

    /// Places are the navigable state, not each selected row. This keeps ⌘[ / ⌘] useful
    /// without turning ordinary arrow-key browsing into a history entry per document.
    private struct Place: Equatable {
        let mode: ViewMode
        let shelf: SmartList
        let folderPath: String?
        let query: String
        let reader: String?
    }

    @State private var backPlaces: [Place] = []
    @State private var forwardPlaces: [Place] = []

    @State private var choosingMoveTarget = false
    // The default for this key is also declared in ContentView.swift and
    // SettingsWindow.swift; all three must agree, since whichever view registers first
    // wins and a mismatch here would make BibTeX output disagree with the Settings toggle.
    /// Shared with `BibFileView`, which draws the file these two decide the shape of.
    /// The file the bibliography pane has built, so the toolbar can copy or save it
    /// without building the same text again.
    private let builtBib: BuiltBibliography = .shared
    @State private var bibCopied = false
    @State private var savingBib = false

    private var bibStyle: BibStyle {
        BibStyle(lineWidth: prefs.bibLineWidth,
                 indent: String(repeating: " ", count: max(0, prefs.bibIndent)),
                 align: prefs.bibAlign,
                 delimiter: prefs.bibDelimiter,
                 trailingComma: prefs.bibTrailingComma,
                 blankLines: prefs.bibBlankLines,
                 sortFields: prefs.bibSortFields,
                 dropAllCaps: prefs.bibDropAllCaps,
                 omit: prefs.bibOmitFile ? ["file"] : [])
    }
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
    /// The projects a file can be filed into from its own menu. Loaded with the shelf
    /// rather than when the palette opens, since the menu is right there on every row.
    @State private var projects: [ProjectSummary] = []
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
    /// the reader is the page. The shelf shows it too: picking a cover is asking what that
    /// document is, and answering with a panel of fields while the page itself is one
    /// click away in another view is the long way round. The bibliography and the
    /// duplicates view have their own second pane and keep it.
    private var showsPage: Bool {
        reader != nil || reading || prefs.viewMode == .list || prefs.viewMode == .catalogue
    }

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
        if reader != key {
            navigate(to: Place(mode: prefs.viewMode, shelf: shelves.current,
                               folderPath: folderScope?.path, query: query, reader: key))
        }
        selected = key
    }

    /// One rung of the ⎋ ladder: out of the reader, back into the collection.
    private func closeReader() {
        if reader != nil, !backPlaces.isEmpty { goBack(); return }
        reader = nil
    }

    private var currentPlace: Place {
        Place(mode: prefs.viewMode, shelf: shelves.current, folderPath: folderScope?.path,
              query: query, reader: reader)
    }

    /// Picking one of the four views means going to it.
    ///
    /// Reading mode and the reader each take the middle of the window, so a view chosen
    /// from under either of them used to light up its icon and change nothing else: the
    /// browser it named was not on screen to be switched. Both are left here, which is
    /// what the icons, the menu and ⌘1 to ⌘4 all say they do.
    private func choose(_ option: ViewMode) {
        setReading(false)
        navigate(to: Place(mode: option, shelf: shelves.current,
                           folderPath: folderScope?.path, query: query, reader: nil))
    }

    private func navigate(to destination: Place) {
        guard destination != currentPlace else { return }
        backPlaces.append(currentPlace)
        if backPlaces.count > 64 { backPlaces.removeFirst() }
        forwardPlaces.removeAll()
        show(destination)
    }

    private func show(_ destination: Place) {
        prefs.viewMode = destination.mode
        shelves.current = destination.shelf
        folderScope = destination.folderPath.map { URL(fileURLWithPath: $0) }
        query = destination.query
        reader = destination.reader
        if let reader = destination.reader { selected = reader }
        runner.search(strippingTagTerms(destination.query), passwords: passwords)
    }

    private func goBack() {
        guard let destination = backPlaces.popLast() else { return }
        forwardPlaces.append(currentPlace)
        show(destination)
    }

    private func goForward() {
        guard let destination = forwardPlaces.popLast() else { return }
        backPlaces.append(currentPlace)
        show(destination)
    }

    /// Every file picked, for the actions that can act on more than one. The anchor,
    /// `selected`, stays what the inspector is showing and what a single-file action uses.
    /// One click sets both; command-click and shift-click add to this and move the anchor.
    @State private var selection: Set<String> = []

    /// What `List` drives. Writing through it keeps the anchor inside the selection, so
    /// the inspector never shows a file that is no longer picked.
    private var multipleSelection: Binding<Set<String>> {
        Binding(
            get: { selection.isEmpty ? Set([selected].compactMap { $0 }) : selection },
            set: { picked in
                pickedByPointer = true
                selection = picked
                if picked.count == 1 { selected = picked.first }
                else if let selected, !picked.contains(selected) { self.selected = picked.first }
                else if picked.isEmpty { selected = nil }
            }
        )
    }

    /// Whether this selection came from a click, clearing the flag as it answers: it says
    /// something about one change, not about the state of the pane.
    private func claimPointerPick() -> Bool {
        guard pickedByPointer else { return false }
        pickedByPointer = false
        return true
    }

    /// One file, and only that one.
    private func pick(_ key: String) {
        pickedByPointer = true
        selected = key
        selection = [key]
    }

    /// Command-click: add a file to what is picked, or take it back out. The anchor
    /// follows the file just clicked, since that is the one being looked at.
    private func toggleInSelection(_ key: String) {
        var picked = selection.isEmpty ? Set([selected].compactMap { $0 }) : selection
        if picked.contains(key) {
            picked.remove(key)
            if selected == key { selected = picked.first }
        } else {
            picked.insert(key)
            selected = key
        }
        selection = picked
    }

    /// Shift-click: everything between the anchor and the file clicked, in the order the
    /// view is drawing them.
    private func extendSelection(to key: String, through order: [String]) {
        selection = Set(selectionRange(from: selected, to: key, in: order))
        selected = key
    }

    /// What an action acts on: everything picked, or the one file the inspector is on.
    private var actingItems: [Item] {
        let keys = selection.isEmpty ? Set([selected].compactMap { $0 }) : selection
        return runner.results.filter { keys.contains($0.key) }
    }

    private var selectedItem: Item? {
        runner.results.first { $0.key == selected }
    }

    /// Everything that could change what `visibleKeys` answers, or what the shelf's
    /// `shown` list holds. Shared so the two caches agree on when to recompute instead of
    /// each guessing at its own signature.
    private var visibilitySignature: VisibleFilter.Signature {
        VisibleFilter.Signature(
            results: runner.resultsToken,
            matching: runner.matchingToken,
            tags: tagIndex.revision,
            query: query,
            scope: folderScope,
            undecidedOnly: prefs.onlyUndecided && prefs.viewMode == .list,
            decisions: runner.reviewed,
            list: shelves.current,
            lists: shelves.revision
        )
    }

    /// The keys the search should show: Runner's own answer for the fields it
    /// understands (name, folder, status, size, pages, year, text), narrowed further by
    /// any `tag:` terms and by `folderScope`, neither of which Runner knows anything
    /// about. Nil means nothing is filtering at all, the same meaning `runner.matchingKeys`
    /// already carries on its own.
    private var visibleKeys: Set<String>? {
        filter.keys(matching: visibilitySignature, compute: computeVisibleKeys)
    }

    private var visibleBib: [BibEntry] { entriesVisible(runner.bib, in: visibleKeys) }

    private var visibleDuplicates: [DuplicateGroup] {
        groupsVisible(runner.duplicates, in: visibleKeys)
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
        if prefs.onlyUndecided && prefs.viewMode == .list {
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
        // Whichever way you were reading the collection, you are still reading it: a
        // folder narrows the list or the shelf you are on rather than moving you to the
        // shelf. Only the two views that are not about files at all switch.
        let showing = prefs.viewMode == .list ? ViewMode.list : .catalogue
        navigate(to: Place(mode: showing, shelf: shelves.current, folderPath: url.path,
                           query: query, reader: nil))
    }

    /// Shows only what carries one tag, by writing the search the search box already
    /// understands rather than adding a second, parallel notion of scope. Any folder scope
    /// is dropped: a tag spans the shelf, and leaving a folder filter on top of it would
    /// silently show a fraction of the tag.
    private func showTag(_ name: String) {
        navigate(to: Place(mode: .catalogue, shelf: shelves.current, folderPath: nil,
                           query: Query.tagSearch(name), reader: nil))
    }

    /// A sidebar shelf is a place in the collection, not a filter applied to the page the
    /// reader happens to be showing. The sidebar lives outside this view, so this notification
    /// is the small bridge that lets a click close the reader even when the chosen shelf was
    /// already active.
    private func showShelf(_ shelf: SmartList) {
        // Spelled out rather than derived from the current place: `replacing(reader: nil)`
        // read as "close the reader" and meant "keep whichever one is open", since a nil
        // argument is exactly how that helper spelled "leave this alone".
        navigate(to: Place(mode: prefs.viewMode, shelf: shelf, folderPath: folderScope?.path,
                           query: query, reader: nil))
    }

    private var aiClient: AIClient {
        AIClient(baseURL: prefs.aiBaseURL, model: prefs.aiModel,
                 apiKey: resolvedKey(useEnvironment: prefs.aiUseEnvironment))
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
        withShelfNavigation(withDialogs(withKeys(core)))
    }

    private func withShelfNavigation<V: View>(_ view: V) -> some View {
        view
            .onChange(of: shelves.current) { _, _ in
                if reader != nil { reader = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showShelfInCatalogue)) { note in
                guard let raw = note.userInfo?["shelf"] as? String,
                      let shelf = SmartList(rawValue: raw) else { return }
                showShelf(shelf)
            }
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
                split
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
            // Moving the anchor by any other means -- the arrows, J and K, a decision --
            // means one file again. Only a modifier click grows a selection.
            if let new, !selection.contains(new) { selection = [new] }
            loadDraft()
        }
            .onAppear {
            ensureSelection()
            installKeyMonitor()
        }
        // A restyle rewrites the suggestions under the current selection.
            .onChange(of: runner.revision) { _, _ in refreshSuggestion() }
            .onChange(of: prefs.sortOrder) { _, order in
            prefs.sortDescending = order.descendsByDefault
            runner.sortResults(by: order, descending: prefs.sortDescending)
        }
            .onChange(of: prefs.sortDescending) { _, down in
            runner.sortResults(by: prefs.sortOrder, descending: down)
        }
            .onChange(of: runner.results.count) { _, count in
            guard count > 0, prefs.sortOrder != .folder else { return }
            runner.sortResults(by: prefs.sortOrder, descending: prefs.sortDescending)
        }
            .onDisappear(perform: removeKeyMonitor)
        // Which regions are actually drawn, so ⌃⇥ skips what is not on screen and ⌃1-⌃5
        // opens what is collapsed rather than appearing to do nothing.
            .onChange(of: regionSignature, initial: true) { _, _ in
            var drawn: Set<Region> = [.document, .status]
            if !reading { drawn.insert(.sidebar) }
            if !prefs.inspectorCollapsed { drawn.insert(.inspector) }
            if showsPage && prefs.contentsShown && annotator.hasPages { drawn.insert(.contents) }
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
            guard case .success(let urls) = outcome, let folder = urls.first else { return }
            let files = actingItems
            guard !files.isEmpty else { return }
            let order = onScreenOrder
            for file in files { runner.move(file, to: folder) }
            afterDeciding(through: order)
        }
            .confirmationDialog("Ask AI for \(runner.pendingCount) names?",
                            isPresented: $confirmingBatchAI) {
            Button("Send \(runner.pendingCount) requests") {
                Task { await runner.identifyPending(client: aiClient, passwords: passwords, rules: rules) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One request per file, each carrying the filename and the first pages' text. "
                 + "You are billed by \(prefs.aiModel)'s provider.")
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
            ToolbarItem(placement: .navigation) {
                contentsToggle
            }
            ToolbarItem(placement: .principal) {
                if SplitLayout.showsViewIcons(paneWidth: viewPaneWidth) {
                    viewIcons
                } else {
                    viewMenu
                }
            }
            ToolbarItem(placement: .primaryAction) {
                searchField
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // A document on screen wants a highlighter, a note and a way to send it
                // on. A collection wants the actions for the view it is in. They are
                // never both what the bar should hold, so only one of them is here.
                if showsReaderActions {
                    readerActions
                } else {
                    contextualActions
                }
                Button { setReading(!reading) } label: {
                    Label("Reading", systemImage: reading ? "book.fill" : "book")
                }
                .tip(reading ? "Show the shelf again" : "Hide everything but the page",
                     key: "⌘⇧R")
                Button { prefs.inspectorCollapsed.toggle() } label: {
                    Label("Inspector", systemImage: prefs.inspectorCollapsed
                          ? "sidebar.right" : "sidebar.trailing")
                }
                .tip(prefs.inspectorCollapsed
                     ? "Show info, rename, notes and the citation"
                     : "Hide the inspector", key: "⌥⌘I")
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .tip("Naming rules, AI, integrations and shortcuts", key: "⌘,")
            }
        }
        .fileExporter(isPresented: $savingBib,
                      document: TextDocument(text: builtBib.text),
                      contentType: .plainText,
                      defaultFilename: bibFileName) { _ in }
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
        .task(id: runner.revision) { await loadProjects() }
    }

    /// Whether the bar is looking at a document rather than at a collection.
    private var showsReaderActions: Bool { showsPage && (reading || reader != nil) }

    /// The colour the next highlight will be painted with, and what it means.
    private var currentStyle: HighlightStyle? {
        palette.styles.first { $0.id.uuidString == prefs.lastHighlightColour } ?? palette.styles.first
    }

    /// The rail beside the page, from the same group as the sidebar button, because it is
    /// the same kind of thing: a pane that opens and shuts. Under
    /// `SplitLayout.contentsFoldsBelow` it opens as a popover from here instead, which is
    /// the only place left that can host one now the inspector's header is four tabs.
    @ViewBuilder
    private var contentsToggle: some View {
        if showsPage && annotator.hasPages {
            Button { prefs.contentsShown.toggle() } label: {
                Label("Contents", systemImage: "sidebar.squares.left")
            }
            .foregroundStyle(prefs.contentsShown ? Color.accentColor : .secondary)
            .tip(prefs.contentsShown ? "Hide the contents" : "Contents and pages", key: "⌘⇧T")
            .popover(isPresented: Binding(
                get: { prefs.contentsShown && SplitLayout.contentsIsPopover(paneWidth: viewPaneWidth) },
                set: { prefs.contentsShown = $0 }
            ), arrowEdge: .bottom) {
                ContentsRail(annotator: annotator)
                    .frame(width: 300, height: 420)
            }
        }
    }

    /// Marking up what is on screen: which highlighter, a note on the selection, and a
    /// way to hand the file on.
    @ViewBuilder
    private var readerActions: some View {
        Menu {
            ForEach(palette.styles) { style in
                Button {
                    prefs.lastHighlightColour = style.id.uuidString
                    if annotator.hasSelection { annotator.highlightSelection(colour: style.nsColor) }
                } label: {
                    // A drawn swatch, not a symbol: a symbol in a menu item is treated as
                    // a template and repainted, so five highlighters came out the same
                    // colour in the one menu whose whole purpose is picking a colour.
                    Label {
                        Text(style.meaning.isEmpty ? "Unnamed" : style.meaning)
                    } icon: {
                        swatchImage(style.nsColor, size: 12)
                    }
                }
            }
        } label: {
            // A drawn swatch: see `swatchImage`. A shape used as a menu's label is not
            // drawn on macOS and a symbol is repainted in the control colour, which left
            // the highlighter button as a bare chevron and then as a black dot.
            swatchImage(currentStyle?.nsColor ?? .systemYellow, size: 14)
                .accessibilityLabel("Highlighter")
        }
        .tip(annotator.hasSelection
             ? "Highlight the selection, in this colour"
             : "Which highlighter the next mark uses")

        Button {
            // A note is a highlight you wrote on. With text selected this makes the mark
            // and opens the notes on it; with nothing selected it is the way to the notes.
            if annotator.hasSelection, let style = currentStyle {
                annotator.highlightSelection(colour: style.nsColor)
            }
            prefs.inspectorPanel = .notes
            prefs.inspectorCollapsed = false
        } label: {
            Label("Note", systemImage: "bubble.left")
        }
        .tip(annotator.hasSelection
             ? "Mark the selection and write about it"
             : "The highlights and notes on this document", key: "⌘⇧N")

        if let item = readerItem ?? selectedItem {
            ShareLink(item: item.currentURL)
                .tip("Send this document somewhere else")
        }
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
        switch prefs.viewMode {
        case .bibliography:
            // The two things anybody does with a bibliography, where the actions are,
            // rather than inside the pane that happens to render the file.
            Button {
                copyText(builtBib.text)
                bibCopied = true
                Task { try? await Task.sleep(for: .seconds(2)); bibCopied = false }
            } label: {
                Label(bibCopied ? "Copied" : "Copy", systemImage: "doc.on.doc")
            }
            .labelStyle(.titleAndIcon)
            .disabled(builtBib.isEmpty)
            .tip("Copy the whole file as it stands")

            Button { savingBib = true } label: {
                Label("Save .bib", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .disabled(builtBib.isEmpty)
            .tip("Write the file somewhere")
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
            // Only when there is no plan yet. Once there is one the bar is about working
            // through it, and rebuilding it is in the menu behind.
            if runner.results.isEmpty {
                Button(action: preview) {
                    Label("Review names", systemImage: "textformat.abc")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!hasSources || runner.busy)
                .keyboardShortcut("p", modifiers: .command)
                .tip("Read-only: works out the new names, touches nothing", key: "⌘P")
            }

            // While there is a plan being worked through, the bar is about the plan: what
            // the model can do to what is left, what confirming the rest would do, and
            // what applying would. `autoIdentify` lives here rather than in the panel
            // because it is a setting for the whole run, not a decision about one file.
            //
            // The reviewer only. On the shelf you are looking at covers, and offering to
            // confirm every name from there is offering to accept names nobody has read.
            if prefs.viewMode == .list, !runner.results.isEmpty {
                if aiReady {
                    // A toolbar's label style is icon-only, so a `Toggle`'s title never
                    // drew and this was a bare unlabelled switch beside two buttons that
                    // did carry words. A toggle button is what a macOS toolbar uses for
                    // an on-off setting anyway, and it can say what it is.
                    Toggle(isOn: $prefs.autoIdentify) {
                        Label("Ask as I go", systemImage: "wand.and.sparkles")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .tip("Ask the model for a name on each file as you reach it")

                    if runner.pendingCount > 0 {
                        Button { confirmingBatchAI = true } label: {
                            Label("Ask AI for \(runner.pendingCount)", systemImage: "sparkles")
                        }
                        .labelStyle(.titleAndIcon)
                        .tip("One request per undecided file. You are billed by the provider.")
                    }
                }

                if runner.pendingCount > 0 {
                    Button {
                        runner.confirmAllPending()
                        ensureSelection()
                    } label: {
                        Label("Confirm all", systemImage: "checkmark.circle")
                    }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .tip("Take every name still pending as it stands", key: "⌘⇧Return")
                }
            }

            // Only when there is something to carry out. A permanently visible, permanently
            // dimmed blue button is a promise the app cannot keep, and it is the loudest
            // thing in the window while it makes it.
            if runner.actionable > 0 {
                Button(action: apply) {
                    Label("Apply \(runner.actionable)", systemImage: "checkmark.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .keyboardShortcut(.return, modifiers: .command)
                .tip(canApply
                     ? "Carry out what you have decided, on disk"
                     : "The plan no longer matches the settings. Review names again.",
                     key: "⌘Return")
            }
        }

        Menu {
            Button("Review names again", action: preview)
                .disabled(!hasSources || runner.busy)
                .keyboardShortcut("p", modifiers: .command)

            Button("Find duplicates") { runner.findDuplicates(passwords: passwords) }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Copy the catalogue as Markdown") {
                copyText(markdownCatalogue(runner.results, known: runner.ai.guesses))
            }
            Button("Copy the bibliography as Markdown") {
                Task {
                    await runner.ensureBibReady()
                    copyText(markdownBibliography(runner.bib))
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .disabled(runner.results.isEmpty)
        .tip("Confirm, undo, compare copies, copy the shelf out")
    }

    /// Applying needs a preview that still matches the settings and at least one file
    /// with a decision behind it.
    ///
    /// It used to need every file reviewed as well, which on a shelf of fourteen thousand
    /// made the button unreachable: confirm one name, and Apply stayed dim with nothing on
    /// screen saying why. Apply only ever touches what was confirmed, trashed or moved, so
    /// the files still pending are not a reason to refuse.
    private var canApply: Bool {
        previewIsCurrent && runner.actionable > 0 && !runner.busy
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
                navigate(to: Place(mode: prefs.viewMode, shelf: list, folderPath: nil,
                                   query: query, reader: nil))
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

    /// The projects, for the file menu's "Add to project". Two columns and a count; cheap
    /// enough to read whenever the shelf changes and never on a row's own render.
    private func loadProjects() async {
        guard let library = Library.shared else { return }
        let found = (try? await library.projects()) ?? []
        let counts = (try? await library.projectMemberCounts()) ?? [:]
        projects = found.map {
            ProjectSummary(id: $0.id, name: $0.name, documentCount: counts[$0.id] ?? 0)
        }
    }

    /// Loaded when the palette opens rather than kept in step: it is two queries, and
    /// they are only ever read by one field that is not usually on screen.
    private func loadPalettePlaces() async {
        guard showingPalette, let library = Library.shared else { return }
        paletteTags = (try? await library.tagCounts()) ?? []
        let projects = (try? await library.projects()) ?? []
        let counts = (try? await library.projectMemberCounts()) ?? [:]
        var summaries: [ProjectSummary] = []
        for project in projects {
            summaries.append(ProjectSummary(id: project.id, name: project.name,
                                            documentCount: counts[project.id] ?? 0))
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

    /// Whether this key event is somebody typing into something.
    ///
    /// A table view is the exception: its own type-select is exactly what this monitor
    /// exists to replace, so a bare letter over a list of files is a command, not a
    /// search-as-you-type.
    private func isTyping(_ event: NSEvent) -> Bool {
        if searchFocused { return true }
        guard let responder = event.window?.firstResponder else { return false }
        if responder is NSTableView { return false }
        return responder is NSTextView || responder is NSControl
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Which commands can be heard here. This pane is where a plan is decided, so the
    /// reviewing keys are live along with everything scoped anywhere or to the library.
    private var activeScope: Command.Scope { reading || reader != nil ? .reader : .reviewing }

    /// The commands that do not need a file in front of them, and so must still work on
    /// an empty shelf — which is exactly when someone reaches for the palette.
    /// What can still be decided while a document is open. Deliberately not every
    /// reviewing command: `n`, `e` and the number keys mean something else to a reader,
    /// and a key that means two things depending on where you last clicked is worse than
    /// a key that means one thing in one place.
    static let decisionsInTheReader: Set<Command> = [
        .trash, .skip, .confirm, .moveTo, .applyOne, .reopen,
    ]

    private static let alwaysAvailable: Set<Command> = [
        .palette, .focusSearch, .shortcuts,
        .focusSidebar, .focusContents, .focusDocument, .focusInspector, .focusStatus,
        .nextRegion, .previousRegion, .back, .forward,
    ]

    private func handle(_ event: NSEvent) -> Bool {
        guard !runner.busy else { return false }
        if event.keyCode == 53 { return escape() }   // ⎋
        let match = Keymap.shared.command(for: event, in: activeScope)
            ?? defaultRegionCommand(for: event)
        let bare = match.flatMap { Keymap.shared.shortcut(for: $0) }?.modifiers.isEmpty ?? true

        // A key with no modifier on it belongs to whatever is being typed into, wherever
        // that is, and the check has to come before any command is matched rather than
        // most of the way down.
        //
        // It used to sit below the reader's own decisions, so a note could not contain
        // the letter D: D is Trash, the reader matched it first, and the file went to the
        // Trash instead of the letter reaching the field. S, M, A, R and Return did the
        // same, which is most of the alphabet a note is written with.
        if bare, isTyping(event) { return false }

        if let match, Self.alwaysAvailable.contains(match) { return perform(match) }
        if reading || reader != nil {
            if handleReaderNavigation(event) { return true }
            // A book open on screen is still a file with a decision pending, and none of
            // these keys is a page key. Without this, reaching for D over an open document
            // did nothing at all: the reader's scope cannot see a reviewing command, and
            // every bare key below is handed to the page.
            if let decision = Keymap.shared.command(for: event, in: .reviewing),
               Self.decisionsInTheReader.contains(decision), selectedItem != nil {
                return perform(decision)
            }
        }

        if regions.focused == .sidebar, handleSidebarKey(event.keyCode) {
            regions.rowFocused = true
            return true
        }

        guard !runner.results.isEmpty, selectedItem != nil else { return false }

        // Anything carrying a modifier is app-level and must work wherever focus is,
        // including while a name is being typed.
        if let match, !bare { return perform(match) }

        // The lists are table views and move themselves; the catalogue is a grid and has
        // no such thing, so the arrows are handled here when a table is not in charge.
        let onATable = event.window?.firstResponder is NSTableView
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        if reading || reader != nil {
            // PDFView owns the page, but its AppKit responder is not reliable when the
            // reader was opened from the keyboard. Keep the common navigation keys here;
            // this also means opening a book never leaves arrows moving the hidden shelf.
            return false
        }
        if !onATable {
            // In a grid a row is a row: up and down cross `gridColumns` items, while left
            // and right move to the neighbour.
            let row = prefs.viewMode == .catalogue ? max(1, gridColumns) : 1
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

    private func handleReaderNavigation(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Arrow keys carry .numericPad; it is an input-source flag, not a user modifier.
        guard modifiers.intersection([.command, .option, .shift, .control]).isEmpty else {
            return false
        }
        let delta: Int?
        switch event.keyCode {
        case 123, 126, 116: delta = -1       // ← ↑ Page Up
        case 49, 124, 125, 121: delta = 1 // Space, → ↓ Page Down
        case 115:
            annotator.go(toPage: 1)
            return true
        case 119:
            annotator.go(toPage: annotator.pageCount)
            return true
        default: return false
        }
        annotator.go(toPage: annotator.page + (delta ?? 0))
        return true
    }

    /// Everything that decides which regions exist right now.
    private var regionSignature: String {
        "\(reading)\(prefs.inspectorCollapsed)\(prefs.contentsShown)\(annotator.hasPages)\(showsPage)"
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
        .findDuplicates, .indexText, .refresh, .revealInFinder, .openExternally,
        .highlight1, .highlight2, .highlight3, .highlight4, .highlight5,
        .addNote, .nextMark, .previousMark,
        .focusSidebar, .focusContents, .focusDocument, .focusInspector, .focusStatus,
        .nextRegion, .previousRegion, .back, .forward, .newTag,
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
        case .viewList: choose(.list)
        case .viewCatalogue: choose(.catalogue)
        case .viewBibliography: choose(.bibliography)
        case .viewDuplicates: choose(.duplicates)
        case .back: goBack()
        case .forward: goForward()
        case .revealInFinder: revealInFinder()
        case .refresh: refresh()
        case .findDuplicates: runner.findDuplicates(passwords: passwords)
        case .indexText:
            if runner.activity.indexing { runner.stopIndexing() }
            else { runner.indexText(passwords: passwords) }
        case .confirmAllPending:
            runner.confirmAllPending()
            ensureSelection()
        case .confirm:
            // On the shelf ⏎ opens the book: a shelf is for reading, and the name is
            // decided in the list, where the page is beside it.
            if prefs.viewMode == .catalogue, reader == nil, let item = selectedItem {
                openReader(item.key)
            } else {
                confirm()
            }
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

        case .focusSidebar:
            focusSidebar()
            regions.focus(.sidebar)
        case .focusContents:
            guard annotator.hasPages else { return false }
            prefs.contentsShown = true
            regions.focus(.contents)
        case .focusDocument:
            listFocused = true
            regions.focus(.document)
        case .focusInspector:
            prefs.inspectorCollapsed = false
            regions.focus(.inspector)
        case .focusStatus: regions.focus(.status)
        case .nextRegion: focusRegion(by: 1)
        case .previousRegion: focusRegion(by: -1)
        case .newTag:
            guard let item = selectedItem else { return false }
            newTagName = ""
            taggingItem = item

        default: return false
        }
        return true
    }

    private func focusRegion(by delta: Int) {
        let next = Regions.next(from: regions.focused, by: delta, available: regions.available)
        switch next {
        case .sidebar: focusSidebar()
        case .contents: prefs.contentsShown = true
        case .document: listFocused = true
        case .inspector: prefs.inspectorCollapsed = false
        case .status: break
        }
        regions.focus(next)
    }

    /// Control-number events can arrive with a control character rather than the visible
    /// digit in `charactersIgnoringModifiers` (notably 3–5 on macOS layouts). Key codes
    /// are stable for the ANSI number row; only use this fallback while the command still
    /// has its default binding, so a user's custom keymap remains authoritative.
    private func defaultRegionCommand(for event: NSEvent) -> Command? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mapping: [UInt16: Command]
        if flags.contains(.control), flags.intersection([.command, .option, .shift]).isEmpty {
            mapping = [18: .focusSidebar, 19: .focusContents, 20: .focusDocument,
                       21: .focusInspector, 23: .focusStatus]
        } else if flags.contains(.command), flags.intersection([.option, .shift, .control]).isEmpty {
            // Some keyboard layouts deliver command-number events without a usable
            // `charactersIgnoringModifiers`; key codes are stable for the number row.
            mapping = [18: .viewList, 19: .viewCatalogue, 20: .viewBibliography,
                       21: .viewDuplicates]
        } else {
            return nil
        }
        guard let command = mapping[event.keyCode], !Keymap.shared.isCustomised(command)
        else { return nil }
        return command
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
        guard prefs.autoIdentify, aiReady, let item = selectedItem,
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
        // A key moved this, whatever the last click left behind: scroll to it.
        pickedByPointer = false
        selected = runner.results[next].key
    }

    private func confirm() {
        guard let item = selectedItem else { return }
        let order = onScreenOrder
        runner.confirm(item, as: draft)
        advance(through: order)
    }

    private func skip() {
        let files = actingItems
        guard !files.isEmpty else { return }
        let order = onScreenOrder
        for file in files { runner.skip(file) }
        afterDeciding(through: order)
    }

    private func skipFolder() {
        guard let item = selectedItem else { return }
        let order = onScreenOrder
        runner.skipFolder(of: item)
        advance(through: order)
    }

    /// Carries out this one file straight away, then moves on like any other decision.
    private func applyNow() {
        guard let item = selectedItem, runner.decision(for: item) != .applied else { return }
        let order = onScreenOrder
        applyOne(item, draft)
        advance(through: order)
    }

    /// One menu, built for whichever file was right-clicked rather than the selected one,
    /// because a right-click on a row people have not selected still means that row.
    private func fileMenu(_ item: Item) -> FileContextMenu {
        // A right-click inside a selection acts on the selection, which is what every
        // file window does; a right-click outside it is about the file under the pointer.
        let many = selection.contains(item.key) ? actingItems : [item]
        return FileContextMenu(
            item: item,
            others: many.count > 1 ? many.count : 0,
            confirm: {
                let order = onScreenOrder
                selected = item.key
                runner.confirm(item, as: item.destinationName)
                advance(through: order)
            },
            identify: {
                selected = item.key
                Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
            },
            moveTo: {
                if !selection.contains(item.key) { pick(item.key) }
                choosingMoveTarget = true
            },
            trash: {
                let order = onScreenOrder
                for file in many { runner.markForDeletion(file) }
                if many.count > 1 { afterDeciding(through: order) }
            },
            skip: {
                let order = onScreenOrder
                for file in many { runner.skip(file) }
                if many.count > 1 { afterDeciding(through: order) }
            },
            convert: {
                selected = item.key
                converting.clear()
                showingMarkdown = true
            },
            projects: projects,
            addToProject: { id in
                let paths = many.map(\.currentURL.path)
                Task {
                    guard let library = Library.shared else { return }
                    _ = try? await addToProject(paths, project: id, library: library)
                    await loadProjects()
                }
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
            await runner.ensureBibReady()
            if let entry = runner.bibByItem[item.key], !entry.isComplete,
               aiReady, runner.ai.guesses[item.key] == nil {
                await runner.identify(item, client: aiClient, passwords: passwords, rules: rules)
                await runner.ensureBibReady()
            }
            guard let entry = runner.bibByItem[item.key] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bibtexBlock(entry, style: bibStyle) + "\n", forType: .string)
            runner.note(.edited, subject: item.relativePath, detail: "citation copied")
        }
    }

    private func markDeleted() {
        let files = actingItems
        guard !files.isEmpty else { return }
        let order = onScreenOrder
        for file in files { runner.markForDeletion(file) }
        afterDeciding(through: order)
    }

    /// After deciding, the picked files are decided: a selection of forty that has just
    /// been trashed is not a selection anybody still wants. The anchor moves on to what is
    /// still waiting, the way it always did for one file.
    private func afterDeciding(through order: [String]) {
        selection = []
        advance(through: order)
    }

    /// The keys in the order this view is drawing them: the folder tree as the list folds
    /// it, or the shelf in its sort order, filtered either way.
    ///
    /// Taken before a decision is recorded, so it still holds the file being decided and
    /// "the next one" means the row under it rather than the top of what is left.
    private var onScreenOrder: [String] {
        switch prefs.viewMode {
        case .list, .bibliography:
            return listRows.compactMap { $0.node.itemKey }
        case .catalogue, .duplicates:
            let keys = visibleKeys
            return runner.results.filter { keys?.contains($0.key) ?? true }.map(\.key)
        }
    }

    /// After a decision, jump to the next file still waiting in the order on screen. When
    /// none are left the selection stays put so the last thing decided is still on screen.
    private func advance(through order: [String]) {
        if let next = nextWaiting(after: selected, in: order, waiting: { key in
            runner.item(key).map { runner.decision(for: $0) == nil } ?? false
        }) {
            pickedByPointer = false
            selected = next
        }
        loadDraft()
    }

    @ViewBuilder
    private var browser: some View {
        if visibleKeys?.isEmpty == true {
            noMatches
        } else {
            switch prefs.viewMode {
            case .catalogue: catalogue
            case .list: list
            case .bibliography: bibliography
            case .duplicates: duplicatesView
            }
        }
    }

    /// A filter that left nothing. Four empty views used to be four blank panes, and a
    /// blank pane reads as a broken app rather than as an answer. The one thing worth
    /// offering here is the thing that would change the answer: a text search over
    /// documents nothing has read cannot match, however the query is written.
    private var noMatches: some View {
        ContentUnavailableView {
            Label("Nothing matches", systemImage: "magnifyingglass")
        } description: {
            if Query(query).needsText, runner.unindexedInSearch > 0 {
                Text("\(runner.unindexedInSearch) of these documents have never been read, "
                     + "so nothing inside them can match yet.")
            } else {
                Text("No file here answers to that. Take a filter off, or search for less.")
            }
        } actions: {
            if Query(query).needsText, runner.unindexedInSearch > 0, !runner.activity.indexing {
                Button("Index text for search") { runner.indexText(passwords: passwords) }
                    .buttonStyle(.borderedProminent)
            }
            if !query.isEmpty {
                Button("Clear the search") {
                    query = ""
                    runner.search("", passwords: passwords)
                }
            }
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
                        BibFileView(entries: visibleBib, name: bibFileName, order: $prefs.bibOrder,
                                    completeOnly: $prefs.bibCompleteOnly, style: bibStyle)
                            .frame(maxWidth: .infinity)
                    }
                } else if prefs.bibShowsFile {
                    BibFileView(entries: visibleBib, name: bibFileName, order: $prefs.bibOrder,
                                completeOnly: $prefs.bibCompleteOnly, style: bibStyle)
                } else {
                    bibEntryList
                }
            }
        }
        .onAppear {
            runner.bibType = prefs.bibType
            runner.ensureBib()
        }
        .onChange(of: runner.revision) { _, _ in runner.ensureBib() }
        .onChange(of: prefs.bibType) { _, new in
            runner.bibType = new
            runner.ensureBib()
        }
    }

    private var bibEntryList: some View {
        Group {
            ScrollViewReader { scroll in
                List(selection: $selected) {
                    ForEach(bibShown) { group in
                        Section("\(group.name) · \(group.entries.count)") {
                            ForEach(group.entries, id: \.itemKey) { entry in
                                BibRow(entry: entry, item: runner.item(entry.itemKey),
                                       passwords: passwords,
                                       isSelected: entry.itemKey == selected)
                                    .tag(entry.itemKey)
                                    .id(entry.itemKey)
                                    // The same gesture the shelf and the list use for
                                    // "show me this document": an entry is a claim about
                                    // a title page, and this is the way to look at it.
                                    .onTapGesture(count: 2) { openReader(entry.itemKey) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .onChange(of: selected) { _, new in
                    guard let new else { return }
                    let ancestors = runner.ancestors(of: new)
                    if !ancestors.allSatisfy(expanded.contains) { expanded.formUnion(ancestors) }
                    guard !claimPointerPick() else { return }
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
                VStack(spacing: Space.step) {
                    ProgressView().controlSize(.large)
                    Text("Comparing \(runner.results.count) files").font(Face.headline)
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
                        ForEach(visibleDuplicates) { group in
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
        let groups = visibleDuplicates
        let identical = groups.filter { $0.kind == .identical }.count
        let sameText = groups.filter { $0.kind == .sameText }.count
        let reclaimable = groups.reduce(0) { $0 + $1.reclaimable }
        return HStack(spacing: Space.step) {
            Text("\(identical) identical, \(sameText) same pages, "
                 + "\(groups.count - identical - sameText) by name")
                .font(Face.control)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(reclaimable), countStyle: .file)
                 + " in spare copies")
                .font(Face.control)
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
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.step)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var bibDocument: String {
        bibtexDocument(runner.bib, includeIncomplete: !prefs.bibCompleteOnly, order: prefs.bibOrder)
    }

    /// The bibliography's own bar: how the entries are ordered, what is filtered out,
    /// and then the entries that are not ready yet, named rather than counted.
    ///
    /// The count on its own said how much was wrong and nothing about where, and the
    /// controls that belong to the whole view were spread across two rows, one of them
    /// inside the file pane. Everything that decides what is on screen is here; the file
    /// pane keeps only what is about the file.
    private var bibBar: some View {
      ScrollView(.horizontal) {
        HStack(spacing: Space.step) {
            Picker("Order", selection: $prefs.bibOrder) {
                ForEach(BibOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tip("By citation key, or grouped the way the folders are")

            Toggle("Complete only", isOn: $prefs.bibCompleteOnly)
                .toggleStyle(.checkbox)
                .tip("Leave out anything missing a title, author or year")
            Toggle("Wrap", isOn: $prefs.bibWrapped)
                .toggleStyle(.checkbox)
                .tip("Fold long lines into the pane; the file itself is unchanged")
            // Only when it has something to say. It is a second, stricter filter than
            // "Complete only", and a bar carrying both at all times reads as two ways of
            // saying the same thing.
            if prefs.bibValidOnly || !bibShortfall.isEmpty {
                Toggle("Valid only", isOn: $prefs.bibValidOnly)
                    .toggleStyle(.checkbox)
                    .tip("Leave out anything missing a field \(prefs.bibStandard.label) requires")
            }

            if !bibShortfall.isEmpty {
                Text(bibShortfall.sentence)
                    .font(Face.control.weight(.medium))
                    .foregroundStyle(Ink.amber)
                    .fixedSize()
                ForEach(bibShortfall.byEntry, id: \.itemKey) { gap in
                    BibGapChip(key: gap.key, missing: gap.missing) {
                        pick(gap.itemKey)
                        expanded.formUnion(runner.ancestors(of: gap.itemKey))
                    }
                }
            }

            Spacer(minLength: Space.roomy)

            // Only where the two panes cannot be shown at once. Above that width the
            // entries and the file they generate are side by side, and a switch between
            // two things already on screen is a switch that does nothing.
            if viewPaneWidth < 900 {
                Picker("", selection: $prefs.bibShowsFile) {
                    Text("Entries").tag(false)
                    Text("File").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tip("Browse the entries, or read the generated file")
            }

            FillGapsButton(entries: bibShortfallEntries, passwords: passwords,
                           client: aiClient, standard: prefs.bibStandard, style: bibStyle)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.step)
      }
      .scrollIndicators(.hidden)
      .fixedSize(horizontal: false, vertical: true)
      .background(.bar)
    }

    /// What the .bib would be called: after the folder it was built from, since that is
    /// what tells two of them apart on disk.
    private var bibFileName: String {
        let source = folderScope?.lastPathComponent ?? runner.results.first?.root.lastPathComponent
        guard let source, !source.isEmpty else { return "library.bib" }
        return source + ".bib"
    }

    /// The entries as the list draws them: in the order chosen in the bar, grouped by the
    /// folder each document sits in.
    private var bibShown: [BibGroup] {
        bibGroups(bibtexOrdered(visibleBib, order: prefs.bibOrder)) { entry in
            guard let item = runner.item(entry.itemKey) else { return "Elsewhere" }
            let folders = item.relativePath.split(separator: "/").dropLast()
            return folders.last.map(String.init) ?? item.root.lastPathComponent
        }
    }

    /// Every entry the standard is not satisfied by, and what each one is short of.
    private var bibShortfall: BibGaps {
        bibGaps(in: visibleBib, kept: kept, standard: prefs.bibStandard)
    }

    private var bibShortfallEntries: [BibEntry] {
        let wanted = Set(bibShortfall.byEntry.map(\.itemKey))
        return visibleBib.filter { wanted.contains($0.itemKey) }
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
        Metric.catalogueColumns(for: width)
    }

    private func catalogueGrid(columns: Int) -> some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: Space.gutter), count: columns)
        let keys = visibleKeys
        let shown = shownFilter.items(matching: visibilitySignature) {
            runner.results.filter { keys?.contains($0.key) ?? true }
        }
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: layout, alignment: .leading, spacing: Space.gutter) {
                    ForEach(shown) { item in
                        CoverCard(
                            item: item,
                            decision: runner.decision(for: item),
                            duplicate: runner.duplicateKind[item.key],
                            passwords: passwords,
                            covers: covers,
                            isSelected: selection.isEmpty
                                ? selected == item.key
                                : selection.contains(item.key),
                            tags: tagIndex.tags(for: item),
                            open: { openReader(item.key) }
                        )
                        .id(item.key)
                        .onTapGesture(count: 2) { openReader(item.key) }
                        // Modifier taps first, or the plain one swallows them and every
                        // click means "just this file".
                        .highPriorityGesture(TapGesture().modifiers(.command).onEnded {
                            toggleInSelection(item.key)
                        })
                        .highPriorityGesture(TapGesture().modifiers(.shift).onEnded {
                            extendSelection(to: item.key, through: shown.map(\.key))
                        })
                        .onTapGesture { pick(item.key) }
                        // Draggable like the list's rows and the sidebar's: a cover is a
                        // file, and dropping one on a project files it there.
                        .onDrag { NSItemProvider(contentsOf: item.currentURL) ?? NSItemProvider() }
                    }
                }
                .padding(Space.gutter)
            }
            .onChange(of: selected) { _, new in
                guard let new, !claimPointerPick() else { return }
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
            Group {
                if showsPage {
                    pageSplit(available: geometry.size.width)
                } else {
                    panelSplit(available: geometry.size.width)
                }
            }
            // The toolbar is laid out somewhere this geometry cannot reach, so the width
            // it decides the view control's shape from is recorded here.
            .onChange(of: geometry.size.width, initial: true) { _, width in
                viewPaneWidth = width
            }
        }
    }

    /// Browser, divider, document. The outline and the inspector panel both fold inside
    /// the document region rather than widening the window (see `ReviewInspector`).
    private func pageSplit(available: CGFloat) -> some View {
        // The contents rail is nested inside the document region, not a sibling here, so
        // it only needs to widen that region's own floor, not the outer reservation
        // `inspectorMaximum` makes for the browser.
        let contentsOpen = prefs.contentsShown && annotator.hasPages
        let minimum = SplitLayout.inspectorMinimum(contentsShown: contentsOpen)
        let maximum = SplitLayout.inspectorMaximum(
            available: available, contentsShown: contentsOpen)
        // Not `min(max(inspectorWidth, minimum), maximum)`: that returns the floor even
        // when the window is narrower than the floor, and the pane is then drawn at a
        // width the window cannot show.
        let width = SplitLayout.inspectorWidth(
            preferred: prefs.documentRegionWidth, available: available, contentsShown: contentsOpen)
        return HStack(spacing: 0) {
            if showsBrowser {
                collection.region(.document)
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
        let width = min(max(prefs.inspectorPanelWidth, floor), maximum)
        return HStack(spacing: 0) {
            collection.region(.document)
            if !prefs.inspectorCollapsed && !overlays {
                divider(width: width, minimum: floor, maximum: maximum, store: $prefs.inspectorPanelWidth)
                documentRegion(paneWidth: width)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
            }
        }
        .overlay(alignment: .trailing) {
            if !prefs.inspectorCollapsed && overlays {
                floatingPanel(width: SplitLayout.panelWidth(paneWidth: available))
            }
        }
    }

    /// The collection, under the bar that says what is filtering it.
    ///
    /// The bar sits over the browser and not over the whole window: the inspector is
    /// about one file and has nothing to do with what is filtering the collection, and a
    /// bar running across both put "4 of 4 shown" above a panel of metadata.
    private var collection: some View {
        VStack(spacing: 0) {
            // Only over the views the bar is about. The bibliography and the duplicates
            // view carry their own bars, and a second one asking whether to show only
            // undecided files is a row about a question those views do not have.
            if !reading && (prefs.viewMode == .list || prefs.viewMode == .catalogue) {
                filterBar
                Divider()
            }
            browser.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The inspector over the browser, on a window with no room to put it beside one.
    private func floatingPanel(width: CGFloat) -> some View {
        documentRegion(paneWidth: width)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .leading) { Divider() }
            .shadow(color: .black.opacity(0.18), radius: 10, x: -3)
    }

    private func divider(width: CGFloat, minimum: CGFloat, maximum: CGFloat,
                         store: Binding<Double>? = nil) -> some View {
        let target = store ?? $prefs.documentRegionWidth
        return dividerBody(width: width, minimum: minimum, maximum: maximum, store: target)
    }

    private func dividerBody(width: CGFloat, minimum: CGFloat, maximum: CGFloat,
                             store: Binding<Double>) -> some View {
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
                                store.wrappedValue = min(max(anchor - value.translation.width,
                                                             minimum), maximum)
                            }
                            .onEnded { _ in dragAnchor = nil }
                    )
            }
    }

    /// The rows the list draws: the tree, folded where it is folded, filtered by the
    /// search, flattened so `List` can be lazy over it.
    ///
    /// It used to be a nested `ForEach` of `DisclosureGroup`s, which builds every row of
    /// every open folder whether or not it is on screen. On fourteen thousand files that
    /// is fourteen thousand views rebuilt on every click, which is why clicking a row felt
    /// slow and sometimes landed on the wrong file: the click arrived while the last one
    /// was still being drawn.
    private var listRows: [FlatNode] {
        flattenTree(runner.tree, expanded: expanded, visible: visibleKeys)
    }

    private var list: some View {
        ScrollViewReader { scroll in
            List(selection: multipleSelection) {
                ForEach(listRows) { row in
                    listRow(row)
                }
            }
            .listStyle(.inset)
            // An NSTableView draws its selection grey unless it is the first responder,
            // which is why the highlight looked inert while the keys were driving it.
            .focused($listFocused)
            .onChange(of: selected) { _, new in
                guard let new else { return }
                let ancestors = runner.ancestors(of: new)
                if !ancestors.allSatisfy(expanded.contains) { expanded.formUnion(ancestors) }
                guard !claimPointerPick() else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func listRow(_ row: FlatNode) -> some View {
        if let key = row.node.itemKey, let item = runner.item(key) {
            ResultRow(item: item, decision: runner.decision(for: item),
                      duplicate: runner.duplicateKind[key], tags: tagIndex.tags(for: item),
                      isCurrent: key == selected)
                .padding(.leading, CGFloat(row.depth) * 14)
                .tag(key)
                .id(key)
                .contextMenu { fileMenu(item) }
                // A real file drag: Finder and anything else that takes one gets a copy.
                // `itemProvider` rather than `onDrag`, because a List drags every selected
                // row when its rows provide one, and dragging six papers onto a project
                // should file six papers, not the one under the pointer.
                .itemProvider { NSItemProvider(contentsOf: item.currentURL) }
        } else {
            FolderRow(node: row.node, depth: row.depth,
                      open: expanded.contains(row.node.id),
                      count: filesUnder(row.node),
                      toggle: { toggleFolder(row.node.id) },
                      show: { showFolder(row.node) })
        }
    }

    private func toggleFolder(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Narrows the shelf to a folder in the list, the same way the sidebar's own tree does.
    private func showFolder(_ node: Node) {
        guard let url = folderURL(of: node) else { return }
        openFolder(url)
    }

    /// Where a folder in the tree sits on disk. A `Node` stores names, so the path is the
    /// source root followed by the names down to it.
    private func folderURL(of node: Node) -> URL? {
        guard let item = firstFile(under: node) else { return nil }
        var url = item.currentURL.deletingLastPathComponent()
        while url.lastPathComponent != node.name, url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        return url.lastPathComponent == node.name ? url : nil
    }

    /// How many files a folder holds, counted through the tree it already has rather than
    /// over the whole result set per row.
    private func filesUnder(_ node: Node) -> Int {
        guard let children = node.children else { return 1 }
        return children.reduce(0) { $0 + filesUnder($1) }
    }

    private func firstFile(under node: Node) -> Item? {
        if let key = node.itemKey { return runner.item(key) }
        for child in node.children ?? [] {
            if let found = firstFile(under: child) { return found }
        }
        return nil
    }

    // MARK: Review inspector

    /// The group the selected file belongs to, if it is one of a set of copies.
    private var selectedDuplicateGroup: DuplicateGroup? {
        guard prefs.viewMode == .duplicates, let selected else { return nil }
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
                autoIdentify: $prefs.autoIdentify,
                moveTo: { choosingMoveTarget = true },
                aiReady: aiReady,
                markDeleted: markDeleted,
                reopen: reopenSelected,
                read: { openReader(item.key) },
                leaveReader: reader == nil ? nil : closeReader,
                reset: { draft = item.destinationName },
                leaveField: { editingName = false; listFocused = true },
                excerpt: runner.excerpt(for: item),
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
    /// What the plan holds, in the words its rows use. Only what is there: a row of
    /// zeroes is a row to read past.
    private var planCounts: [(PlanState, Int)] {
        var counts: [(PlanState, Int)] = []
        if runner.confirmedCount > 0 { counts.append((.confirmed, runner.confirmedCount)) }
        if runner.appliedCount > 0 { counts.append((.applied, runner.appliedCount)) }
        if runner.skippedCount > 0 { counts.append((.skipped, runner.skippedCount)) }
        if runner.deletedCount > 0 { counts.append((.trash, runner.deletedCount)) }
        if runner.movedCount > 0 { counts.append((.moving, runner.movedCount)) }
        let locked = runner.statusCounts.first { $0.0 == .locked }?.1 ?? 0
        if locked > 0 { counts.append((.locked, locked)) }
        return counts
    }

    private var filterBar: some View {
        HStack(spacing: Space.step) {
            ScrollView(.horizontal) {
                HStack(spacing: Space.step) {
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
                    ForEach(planCounts, id: \.0) { state, count in
                        PlanCountPill(state: state, count: count)
                    }
                }
                .padding(.vertical, Space.hair)
            }
            .scrollIndicators(.hidden)
            // The chips give way, never the counts and the order: a scroll view takes
            // every point it is offered, and what it took here was the word "Date".
            .layoutPriority(-1)

            Spacer(minLength: Space.snug)

            searchWarning

            if selection.count > 1 {
                Text("\(selection.count) selected")
                    .font(Face.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                    .tip("Skip, trash and Move to act on all of them")
            }

            Text(shownLabel)
                .font(Face.caption.monospacedDigit())
                .foregroundStyle(visibleKeys?.isEmpty == true ? Ink.amber : .secondary)
                .fixedSize()

            if prefs.viewMode == .list {
                // A switch, not a button that looks pressed. It answers yes or no to one
                // question -- show me only what I have not decided -- which is what a
                // switch is for, and it reads as on or off from across the window.
                Toggle("Only undecided", isOn: $prefs.onlyUndecided)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(Face.caption)
                    .fixedSize()
                    .tip("Hide everything already confirmed, skipped or trashed")
            }

            sortMenu
        }
        .padding(.horizontal, Space.roomy)
        .frame(height: Metric.filterBar)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// What the window is looking at, in the title where the platform puts it.
    ///
    /// It said the internal product name on every screen, which is the one thing a person looking at
    /// the window already knows.
    /// One name, or the first and "et al.". Four authors written out is wider than the
    /// title above it, and a subtitle that has to be truncated says less than a short one.
    private func shortAuthor(_ author: String?) -> String? {
        guard let author, !author.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: ",;&")
        let names = author.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "and" }
        guard let first = names.first else { return author }
        return names.count > 1 ? "\(first) et al." : first
    }

    /// What the open document says about itself, but only when the open document is this
    /// one. The annotator is attached to whatever the page is showing, and a title read
    /// off the last file is worse than no title at all.
    private func statedByDocument(_ item: Item, _ stated: String?) -> String? {
        guard let stated, annotator.url == item.currentURL else { return nil }
        return stated
    }

    private var placeTitle: String {
        if let item = readerItem ?? (reading ? selectedItem : nil) {
            // What the book calls itself first. A reader is looking at a title page, and
            // a window titled `2017-verifying-strong-eventual-...-gomes.pdf` above it is
            // the filename twice over: the status bar already carries the path.
            //
            // The open document is asked before the plan is. Both know the title, but the
            // plan only learns it once a run has read the file, so a window opened
            // straight onto a document was named after its filename until then.
            if let stated = statedByDocument(item, annotator.statedTitle) { return stated }
            let planned = item.documentInfo["Title"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let planned, !planned.isEmpty { return planned }
            return runner.ai.guesses[item.key]?.title
                ?? (item.destinationName as NSString).deletingPathExtension
        }
        let terms = Query(query).terms
        switch prefs.viewMode {
        case .bibliography: return "Bibliography"
        case .duplicates: return "Duplicates"
        case .list where !runner.results.isEmpty:
            // The list is the reviewer, and what it is showing is a plan. Naming it after
            // the shelf it was built from said where the files came from, which the
            // sidebar already says, rather than what the window is for.
            return "Review plan"
        default:
            if terms.count == 1, let term = terms.first, term.field == "tag" {
                return "Tag: \(term.value)"
            }
            return folderScope?.lastPathComponent ?? shelves.current.title
        }
    }

    /// What is in the place, counted. The transient part of this -- what is running, what
    /// has been decided -- is in the status bar and deliberately not here.
    private var placeSubtitle: String {
        if let item = readerItem ?? (reading ? selectedItem : nil) {
            let guess = runner.ai.guesses[item.key]
            let planned = item.documentInfo["Author"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let author = shortAuthor(statedByDocument(item, annotator.statedAuthor)
                                     ?? (planned?.isEmpty == false ? planned : nil)
                                     ?? guess?.author)
            // Where you are, not how long it is. "248 pages" is a fact about the file and
            // belongs in the Info tab; the subtitle of a window with a page in it should
            // say which page.
            let total = annotator.pageCount > 0 ? annotator.pageCount : item.pageCount
            let where_ = total.map { "page \(annotator.page) of \($0)" }
            return [author, guess?.year, where_]
                .compactMap { $0 }.joined(separator: " · ")
        }
        switch prefs.viewMode {
        case .list where !runner.results.isEmpty:
            let total = runner.results.count
            let done = runner.reviewed
            return "\(total) file\(total == 1 ? "" : "s") \u{00B7} \(done) decided "
                + "\u{00B7} \(runner.pendingCount) to go"
        case .duplicates:
            let groups = visibleDuplicates
            let files = groups.reduce(0) { $0 + $1.items.count }
            return "\(groups.count) group\(groups.count == 1 ? "" : "s") · \(files) files"
        case .bibliography:
            let entries = visibleBib.count
            let where_ = folderScope?.lastPathComponent
                ?? runner.results.first?.root.lastPathComponent
            return [where_, "\(entries) entr\(entries == 1 ? "y" : "ies")",
                    "rebuilt as you change anything"]
                .compactMap { $0 }.joined(separator: " · ")
        default:
            let shown = visibleKeys?.count ?? runner.results.count
            let reachable = max(0, sourceCount - unavailableSourceCount)
            let sources = "\(reachable) source\(reachable == 1 ? "" : "s")"
            let missing = unavailableSourceCount > 0
                ? " · \(unavailableSourceCount) unavailable"
                : ""
            return "\(shown) shown · \(sources)\(missing)"
        }
    }

    /// How much of the collection is on screen. Always M of N, so the number never has to
    /// be read twice to find out whether anything is filtering.
    private var shownLabel: String {
        let shown = visibleKeys?.count ?? runner.results.count
        return "\(shown) of \(runner.results.count) shown"
    }

    /// The two ways a search can quietly answer the wrong question: a field that does not
    /// exist, which the grammar turns into a literal word, and a question about the inside
    /// of documents nothing has read. Neither is worth an alert; both are worth saying.
    @ViewBuilder
    private var searchWarning: some View {
        let unknown = Query.unknownFields(in: query)
        if let field = unknown.first {
            Label("no field called \(field)", systemImage: "questionmark.circle")
                .font(Face.caption)
                .foregroundStyle(Ink.amber)
                .fixedSize()
                .tip("Fields are title, author, abstract, text, name, was, folder, tag, "
                     + "year, pages and size. Anything else is searched for as written.")
        } else if Query(query).needsText, runner.unindexedInSearch > 0 {
            HStack(spacing: Space.tight) {
                Text("\(runner.unindexedInSearch) not indexed")
                    .font(Face.caption.monospacedDigit())
                    .foregroundStyle(Ink.amber)
                if runner.activity.indexing {
                    Text("reading…").font(Face.caption).foregroundStyle(.secondary)
                } else {
                    Button("Index") { runner.indexText(passwords: passwords) }
                        .buttonStyle(.plain)
                        .font(Face.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .fixedSize()
            .tip("Searching inside a document needs its text read once. Files never read "
                 + "cannot match, and are not counted as a no.")
        }
    }

    private func removeChip(_ piece: String) {
        query = Query.removing(piece, from: query)
        runner.search(strippingTagTerms(query), passwords: passwords)
    }

    /// A filter, with the ✕ that takes it off. Nothing here is a state you cannot leave.
    private func chip(_ text: String, icon: String?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Space.tight) {
            if let icon { Image(systemName: icon).font(Face.micro) }
            Text(text).font(Face.caption).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.tight)
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
                    prefs.sortOrder = order
                } label: {
                    if order == prefs.sortOrder { Label(order.label, systemImage: "checkmark") }
                    else { Text(order.label) }
                }
            }
            Divider()
            Toggle("Largest or newest first", isOn: $prefs.sortDescending)
        } label: {
            HStack(spacing: Space.tight) {
                Image(systemName: prefs.sortDescending ? "arrow.down" : "arrow.up")
                Text(prefs.sortOrder.label)
            }
            .font(Face.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tip("Reorders within each folder, and across the catalogue")
    }

    /// The four views of the same files, as four icons. A menu costs a click to reach a
    /// view and says nothing about which views exist; the row is one click and reads as a
    /// row of choices, which is what it is.
    private var viewIcons: some View {
        HStack(spacing: Space.hair) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, option in
                Button {
                    choose(option)
                } label: {
                    Image(systemName: option.icon)
                        .frame(width: 28, height: 20)
                        .contentShape(Rectangle())
                        // On the label as well as the button: a toolbar's principal item
                        // is hosted in the title area, where help on the control alone is
                        // not always the thing the pointer is over.
                        .help("\(option.label)  (⌘\(index + 1))")
                }
                .buttonStyle(.plain)
                .foregroundStyle(option == prefs.viewMode ? Color.accentColor : .secondary)
                .background(option == prefs.viewMode ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: Metric.control))
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option == prefs.viewMode ? .isSelected : [])
                .tip(option.label, key: "⌘\(index + 1)")
            }
        }
        .fixedSize()
    }

    /// The same four views where the toolbar has no room for them: search, the actions for
    /// the mode and the panel buttons are all in this bar too.
    private var viewMenu: some View {
        Menu {
            ForEach(ViewMode.allCases) { option in
                Button {
                    choose(option)
                } label: {
                    Label(option.label, systemImage: option.icon)
                }
            }
        } label: {
            Text(prefs.viewMode.label).help("Which view of the same files  (⌘1 to ⌘4)")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("View: \(prefs.viewMode.label)")
        .fixedSize()
        .tip("Which view of the same files", key: "⌘1 to ⌘4")
    }

    private var searchField: some View {
        HStack(spacing: Space.tight) {
            fieldsMenu
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
            // The tooltip said `/` focuses this, which is a fact you find once and then
            // have to remember. A key is worth one cap of space in the field it belongs to.
            if query.isEmpty && !searchFocused {
                Text("/")
                    .font(Face.mono)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.tight)
                    .padding(.vertical, Space.hair)
                    .fittedBackground(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    runner.search("", passwords: passwords)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .tip("Clear the search")
            }
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.tight)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: SplitLayout.searchFieldWidth(paneWidth: viewPaneWidth))
        .tip("Search names, or narrow by field: title, author, abstract, text, folder, "
             + "tag, year, pages, size", key: "/")
    }

    /// The grammar, offered rather than described. It lived in a tooltip, which is a place
    /// people find a fact once and then have to remember it; a menu is where they can go
    /// back for it. Choosing a field types it and leaves the caret after the colon.
    private var fieldsMenu: some View {
        Menu {
            ForEach(Query.knownFields, id: \.self) { field in
                Button(fieldMenuLabel(field)) { appendField(field) }
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .help("Narrow the search by a field")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Search fields")
        .tip("Narrow the search by a field")
    }

    private func fieldMenuLabel(_ field: String) -> String {
        switch field {
        case "title": return "title:  what the document calls itself"
        case "author": return "author:  who it says wrote it"
        case "abstract": return "abstract:  the opening of the document"
        case "text": return "text:  anywhere inside the document"
        case "name": return "name:  the new filename"
        case "was": return "was:  the original filename"
        case "folder": return "folder:  the folder it sits in"
        case "tag": return "tag:  a tag you gave it"
        case "year": return "year:  the name, the metadata or the file's own year"
        case "pages": return "pages:  how long it is, with > or <"
        case "size": return "size:  how big it is, with > or <"
        default: return "\(field):"
        }
    }

    private func appendField(_ field: String) {
        let separator = query.isEmpty || query.hasSuffix(" ") ? "" : " "
        query += separator + field + (field == "pages" || field == "size" ? ">" : ":")
        searchFocused = true
    }

    @ViewBuilder
    private var duplicateControls: some View {
        if runner.findingDuplicates {
            ProgressView().controlSize(.small)
            Text("Comparing…").font(Face.control).foregroundStyle(.secondary)
        } else if runner.duplicates.isEmpty {
            Button("Find duplicates") { runner.findDuplicates() }
                .controlSize(.small)
        } else {
            let identical = runner.duplicates.filter { $0.kind == .identical }.count
            let sameText = runner.duplicates.filter { $0.kind == .sameText }.count
            let likely = runner.duplicates.count - identical - sameText
            Text("\(identical) identical, \(sameText) same pages, \(likely) by name")
                .font(Face.control)
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
        if hasSources && unavailableSourceCount == sourceCount {
            ContentUnavailableView {
                Label("Source unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("Mount the source volume, then try again. Its location is kept here.")
            } actions: {
                Button("Try again", action: preview)
            }
        } else if hasSources {
            ContentUnavailableView {
                Label("Ready to run", systemImage: "wand.and.sparkles")
            } description: {
                let missing = unavailableSourceCount > 0
                    ? " \(unavailableSourceCount) currently unavailable."
                    : ""
                Text("\(sourceCount) source\(sourceCount == 1 ? "" : "s") queued.\(missing) Plan first, then apply.")
            } actions: {
                Button("Review names", action: preview).buttonStyle(.borderedProminent)
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
@Observable
final class CatalogueTags {
    private let library: Library?
    /// Document id -> tag names.
    private(set) var byDocument: [String: [String]] = [:]
    /// Item key -> document id, resolved lazily as items are seen. A file the library has
    /// never heard of (just noticed, or seen while the store could not open) has no entry
    /// here, which is the true state: it cannot be tagged until it does.
    private(set) var documentID: [String: String] = [:]
    /// Every tag name in use anywhere, offered when adding one so nobody has to retype or
    /// misspell a tag that already exists.
    private(set) var everyTag: [String] = []
    /// Bumped whenever the tag tables change, so a view filtering by tag can tell in one
    /// comparison whether its last answer still holds.
    private(set) var revision = 0

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

    // Mirrors `add`: the in-memory table only moves once the write has actually
    // succeeded, so a failed delete does not make the chip vanish and then reappear on
    // the next refresh.
    @discardableResult
    func remove(_ name: String, from item: Item) async -> Bool {
        guard let library, let id = documentID[item.key] else { return false }
        guard (try? await library.removeTag(name, fromDocument: id)) != nil else { return false }
        byDocument[id]?.removeAll { $0 == name }
        return true
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
        VStack(alignment: .leading, spacing: Space.roomy) {
            Text("New Tag").font(Face.headline)
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
    static let openFolderInCatalogue = Notification.Name("PaperShelf.openFolderInCatalogue")
    /// Posted with the tag's name in `userInfo["tag"]` by the sidebar's Tags panel.
    static let showTagInCatalogue = Notification.Name("PaperShelf.showTagInCatalogue")
    /// Posted with a `SmartList.rawValue` in `userInfo["shelf"]` by the sidebar's Library
    /// section. The catalogue owns the reader state, so it must receive the click to leave
    /// the page even when the shelf was already selected.
    static let showShelfInCatalogue = Notification.Name("PaperShelf.showShelfInCatalogue")
    /// Posted with a project's `Int64` id in `userInfo["id"]` by the palette, which can
    /// reach a project the sidebar would have to be scrolled to.
    static let openProject = Notification.Name("PaperShelf.openProject")
}

// MARK: - Review inspector

/// The bibliography of what the search left on screen. The entries are the same documents
/// the list would be showing, so a query that narrows one has to narrow both.
func entriesVisible(_ entries: [BibEntry], in visible: Set<String>?) -> [BibEntry] {
    guard let visible else { return entries }
    return entries.filter { visible.contains($0.itemKey) }
}

/// A duplicate group survives if any of its copies did. Dropping the copies that did not
/// match would leave a group of one, which is the one thing a duplicate is not.
func groupsVisible(_ groups: [DuplicateGroup], in visible: Set<String>?) -> [DuplicateGroup] {
    guard let visible else { return groups }
    return groups.filter { group in group.items.contains { visible.contains($0.key) } }
}

/// Whether anything under this node survived the current filter. Shared by the list and
/// the bibliography, which draw the same tree and have to hide the same branches.
func anyVisible(_ node: Node, _ visible: Set<String>) -> Bool {
    if let key = node.itemKey { return visible.contains(key) }
    return (node.children ?? []).contains { anyVisible($0, visible) }
}

/// The run a shift-click takes: from the anchor to the file clicked, in the order the view
/// is drawing them, in either direction. An anchor that is no longer on screen selects the
/// file clicked and nothing else, which is what a person expects and is a good deal better
/// than selecting everything between a stale row and this one.
func selectionRange(from anchor: String?, to key: String, in order: [String]) -> [String] {
    guard let anchor, anchor != key,
          let from = order.firstIndex(of: anchor),
          let to = order.firstIndex(of: key)
    else { return [key] }
    let range = from < to ? from...to : to...from
    return Array(order[range])
}

/// Where a decision leaves you: the next file still waiting, in the order the view is
/// drawing them, starting below the anchor and wrapping once around.
///
/// `order` is the order on screen, which is not the order of the results: the list is a
/// folder tree, the shelf is sorted, and both can be filtered. Walking the results instead
/// is how confirming a file used to land on one from somewhere else entirely.
func nextWaiting(after anchor: String?, in order: [String],
                 waiting: (String) -> Bool) -> String? {
    guard !order.isEmpty else { return nil }
    let start = anchor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    for offset in 0..<order.count {
        let key = order[(start + offset) % order.count]
        if waiting(key) { return key }
    }
    return nil
}

/// A folder in the list: a chevron that folds it, its name, and how much is in it.
///
/// Its own view so a click on a row does not rebuild every other row, and so the chevron
/// and the row mean two different things: fold, and show me only this.
struct FolderRow: View {
    let node: Node
    let depth: Int
    let open: Bool
    let count: Int
    let toggle: () -> Void
    let show: () -> Void

    var body: some View {
        HStack(spacing: Space.snug) {
            Button(action: toggle) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(Face.micro)
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tip(open ? "Fold this folder" : "Open this folder")

            // A heading over the files under it, rather than a row that looks like one:
            // a folder icon in a column of documents is one more thing to read past.
            Text(node.name)
                .font(Face.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\u{00B7} \(count)")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, Space.hair)
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: show)
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Show only this folder", action: show)
        }
    }
}


/// What one row of a plan is, in one word.
///
/// A file in a plan has two things true of it at once -- what the run made of it, and what
/// you decided about it -- and the row used to show both, a glyph for one and a pill for
/// the other. This is the single answer: the decision where there is one, and what the
/// plan intends to do where there is not.
enum PlanState: String {
    case reviewing, confirmed, applied, renamed, unchanged
    case locked, duplicate, skipped, trash, moving, failed

    var label: String {
        switch self {
        case .reviewing: return "Reviewing"
        case .confirmed: return "Confirmed"
        case .applied: return "Applied"
        case .renamed: return "Renamed"
        case .unchanged: return "Unchanged"
        case .locked: return "Locked"
        case .duplicate: return "Duplicate"
        case .skipped: return "Skipped"
        case .trash: return "Trash"
        case .moving: return "Moving"
        case .failed: return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .reviewing: return "play.fill"
        case .confirmed: return "checkmark"
        case .applied: return "checkmark.seal.fill"
        case .renamed: return "circle.dotted"
        case .unchanged: return "clock"
        case .locked: return "lock.fill"
        case .duplicate: return "doc.on.doc"
        case .skipped: return "minus"
        case .trash: return "trash"
        case .moving: return "arrow.right"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Darkened for light and lifted for dark: the system greens and oranges sit around
    /// 2:1 on a light background, which is unreadable at caption size.
    var colour: Color {
        switch self {
        case .reviewing, .renamed: return Ink.blue
        case .confirmed, .applied: return Ink.green
        case .unchanged, .skipped: return Ink.grey
        case .locked: return Ink.amber
        case .duplicate, .moving: return Ink.purple
        case .trash, .failed: return Ink.red
        }
    }

    /// What it means, for the tooltip on both the glyph and the pill.
    var explanation: String {
        switch self {
        case .reviewing: return "The file the panel is asking about"
        case .confirmed: return "Confirmed, and included when you apply"
        case .applied: return "Already carried out on disk"
        case .renamed: return "Will be renamed when you apply"
        case .unchanged: return "Already named correctly; nothing to do"
        case .locked: return "Encrypted and no password matched"
        case .duplicate: return "Another copy of this file is in the plan"
        case .skipped: return "Left alone; nothing will happen to it"
        case .trash: return "Headed for the Trash when you apply"
        case .moving: return "Moving to the folder you chose"
        case .failed: return "Something went wrong; the note says what"
        }
    }

    /// The mark down the left of the plan, which is the column a reviewer scans.
    var glyph: some View {
        Image(systemName: icon)
            .font(Face.caption)
            .foregroundStyle(colour)
            .help(explanation)
    }
}

/// How many of the plan are in one state, for the bar over it.
struct PlanCountPill: View {
    let state: PlanState
    let count: Int

    var body: some View {
        Text("\(count) \(state.label.lowercased())")
            .font(Face.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(state.colour)
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.hair)
            .fittedBackground(state.colour.opacity(Ink.fill), in: RoundedRectangle(cornerRadius: Metric.control))
            .tip(state.explanation)
    }
}

/// The state of one row, on the right of it.
struct PlanPill: View {
    let state: PlanState
    /// Whether the list is painting its own selection colour behind this.
    ///
    /// A pill drawn in its own ink at a sixth opacity vanishes into that: "Reviewing" is
    /// blue, the selected row is blue, and the one word saying what the row is doing was
    /// the least readable thing on screen. On the selected row the pill borrows the row's
    /// own foreground, the way the tag chips beside it already do, and the word carries
    /// the meaning the colour was carrying everywhere else.
    var onSelection = false

    var body: some View {
        Text(state.label)
            .font(Face.caption.weight(.semibold))
            .foregroundStyle(onSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(state.colour))
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.hair)
            .fittedBackground(onSelection
                              ? AnyShapeStyle(.secondary.opacity(0.28))
                              : AnyShapeStyle(state.colour.opacity(Ink.fill)),
                              in: RoundedRectangle(cornerRadius: Metric.control))
            .tip(state.explanation)
    }
}

struct ResultRow: View {
    let item: Item
    let decision: Decision?
    var duplicate: DuplicateGroup.Kind?
    var tags: [String] = []
    /// The row being reviewed right now. It reads as "Reviewing" rather than as whatever
    /// it will be, because that is what it is: the one the panel is asking about.
    var isCurrent: Bool = false

    /// Two lines and one pill.
    ///
    /// The old name grey above, what it becomes at full weight below, and the state on
    /// the right. Both are set in the same monospace, because the two of them are read
    /// against each other character by character -- that is the whole review. Size, pages
    /// and dates are in the inspector: a plan is read down the column of names, and
    /// anything else on the row is something to read past.
    var body: some View {
        HStack(alignment: .top, spacing: Space.step) {
            state.glyph.frame(width: 15).padding(.top, Space.hair)

            VStack(alignment: .leading, spacing: Space.hair) {
                if isRenamed {
                    Text(item.sourceName)
                        .font(Face.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(shownName)
                        .font(Face.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(decision == .deleted)
                } else {
                    Text(item.sourceName)
                        .font(Face.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(decision == .deleted)
                    // Not a name, so not set like one: this line says what will happen
                    // to the file above it, and the plan is read down the names.
                    Text(outcome)
                        .font(Face.caption)
                        .foregroundStyle(item.status == .failed
                                         ? AnyShapeStyle(Ink.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                // On their own line: a row of chips beside the names would take the room
                // the names need, and the names are what a plan is read down.
                if !tags.isEmpty { tagChips }
            }

            Spacer(minLength: Space.step)

            PlanPill(state: state, onSelection: isCurrent)
        }
        .padding(.vertical, Space.tight)
        .opacity(decision == .skipped ? 0.55 : 1)
    }

    /// What this row is, in one word.
    ///
    /// The row used to carry two of these: a glyph for what you had decided and a pill for
    /// what the file was, so a confirmed rename said "confirmed" on the left and "renamed"
    /// on the right and a reader had to combine them. A decision, once made, is the answer;
    /// until then the answer is what the plan intends to do.
    private var state: PlanState {
        switch decision {
        case .confirmed: return .confirmed
        case .applied: return .applied
        case .skipped: return .skipped
        case .deleted: return .trash
        case .moveTo: return .moving
        case nil: break
        }
        if isCurrent { return .reviewing }
        if item.status == .locked { return .locked }
        if item.status == .failed { return .failed }
        if duplicate != nil { return .duplicate }
        return isRenamed ? .renamed : .unchanged
    }

    private var isRenamed: Bool {
        decision != .deleted && shownName != item.sourceName
    }

    /// What happens to a file that is not being renamed, in the words the plan uses.
    private var outcome: String {
        if decision == .deleted { return "moving to the Trash" }
        if !item.message.isEmpty { return item.message }
        switch decision {
        case .skipped: return "left alone"
        case .applied: return "applied"
        default: return "already named correctly"
        }
    }

    private var shownName: String {
        if case .confirmed(let name) = decision { return name }
        return item.destinationName
    }

    /// What this file is tagged, read from the tag index rather than a query of its own
    /// (see `CatalogueTags`), so a row full of files costs one lookup each, not one
    /// round trip to the library each.
    private var tagChips: some View {
        HStack(spacing: Space.tight) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(Face.micro)
                    .padding(.horizontal, Space.tight)
                    .padding(.vertical, Space.hair)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
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
    var covers: Covers
    let isSelected: Bool
    /// What this file is tagged with. Shown on the card so a shelf can be read by tag at a
    /// glance rather than one right-click at a time.
    var tags: [String] = []
    /// Opens this document in the reader. Wired at the grid call site to `openReader`, so
    /// the shelf's default view -- otherwise colour-only for its selection ring, and
    /// silent about what a card even is -- is reachable and actionable without a mouse.
    var open: () -> Void = {}
    /// This card's own cover. Held here rather than read out of a shared counter, so a
    /// render landing anywhere else on the shelf does not redraw this card.
    @State private var cover: NSImage?
    /// Set once a render has been tried and produced nothing, so the card can say the file
    /// could not be read instead of showing the placeholder forever.
    @State private var unreadable = false

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

    /// What VoiceOver should say for this card: the title, then the decision and status
    /// in the same words their own tooltips already use (see `Tooltips.swift`), so the
    /// shelf does not invent a second vocabulary for what "confirmed" or "locked" means.
    private var accessibilitySummary: String {
        "\(bookTitle). \(decision?.explanation ?? undecidedExplanation). \(item.status.explanation)"
    }

    private var selectionTint: Color {
        Regions.shared.hasKeys(.document) ? Color.accentColor : Color.secondary
    }

    private var physical: String {
        [
            item.pageCount.map { "\($0) pp" },
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            // `Color.clear` carries the box, not the cover.
            //
            // A resizable image has no size of its own until something proposes one, and
            // in a vertical grid nothing proposes a height -- so the ZStack that used to
            // be here took its height from whichever page it happened to hold, and a card
            // holding an A4 page stood taller than one holding a letter page with its
            // title ten points further down. An empty flexible view takes the box's ratio
            // and nothing else, and the cover is laid inside what it decides.
            Color.clear
                .aspectRatio(1 / Metric.coverAspect, contentMode: .fit)
                .overlay {
                    if let cover {
                        Image(nsImage: cover)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Metric.card))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: Metric.card)
                            .fill(.quaternary.opacity(0.5))
                            .overlay {
                                if unreadable, item.status != .locked {
                                    // A cover that will not come is not a cover still
                                    // coming. Same amber the sidebar uses for a source it
                                    // cannot read, and usually the same cause: a disk
                                    // that has stopped serving its own bytes.
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Ink.amber)
                                        .help("This file could not be read. The disk may "
                                              + "be failing, or the PDF may be damaged.")
                                } else {
                                    Image(systemName: item.status == .locked
                                          ? "lock.fill" : "book.closed")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }
                }
            .overlay(alignment: .topTrailing) { badges }
            .task(id: "\(item.key)#\(covers.generation)") {
                if let hit = covers.cached(item) { cover = hit; unreadable = false; return }
                cover = nil
                unreadable = covers.couldNotRender(item)
                guard !unreadable else { return }
                cover = await covers.cover(for: item, passwords: passwords,
                                           height: CoverCard.rasterHeight)
                unreadable = cover == nil
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
                .foregroundStyle(.secondary)

            Text(physical)
                .font(Face.micro.monospacedDigit())
                .foregroundStyle(.secondary)

            if !tags.isEmpty {
                FlowRow(spacing: Space.tight) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(Face.micro)
                            .lineLimit(1)
                            .padding(.horizontal, Space.tight)
                            .padding(.vertical, Space.hair)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: Metric.control))
                    }
                }
            }
        }
        .padding(Space.step)
        // Accent while the shelf has the arrow keys, grey while they are somewhere else.
        // The shelf is always `.document`; a card is only ever drawn here.
        .background(
            RoundedRectangle(cornerRadius: Metric.card)
                .fill(isSelected ? selectionTint.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.card)
                .strokeBorder(isSelected ? selectionTint : .clear, lineWidth: 1.5)
        )
        .opacity(decision == .skipped ? 0.5 : 1)
        .contentShape(Rectangle())
        // The shelf is the app's default view, and until now a card here had no
        // accessibility exposure at all: no grouping, no label, no selected trait, no
        // action -- the selection ring was colour only. `.combine` reads the card as one
        // element instead of a pile of unlabeled text and images.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { open() }
    }

    @ViewBuilder
    private func decisionBadge(_ decision: Decision) -> some View {
        switch decision {
        case .confirmed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green)
        case .applied: Image(systemName: "checkmark.seal.fill").foregroundStyle(Ink.green)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .deleted: Image(systemName: "trash.circle.fill").foregroundStyle(Ink.red)
        case .moveTo: Image(systemName: "arrow.right.circle.fill").foregroundStyle(Ink.purple)
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: Space.tight) {
            if let duplicate {
                Image(systemName: duplicateIcon(duplicate))
                    .foregroundStyle(duplicateColour(duplicate))
                    .help(duplicateExplanation(duplicate))
            }
            if let decision {
                decisionBadge(decision)
                    // The badge is a colour and a shape and nothing else, which is no
                    // answer at all to somebody who cannot see either. The same sentence
                    // the tooltip gives is the one VoiceOver reads.
                    .help(decision.explanation)
                    .accessibilityLabel(decision.explanation)
            }
        }
        .font(Face.body)
        .padding(Space.tight)
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
        .font(Face.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.hair)
        .fittedBackground(color.opacity(0.16), in: RoundedRectangle(cornerRadius: Metric.control))
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
    var runner: Runner

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
            HStack(spacing: Space.step) {
                Label(duplicateLabel(group.kind), systemImage: duplicateIcon(group.kind))
                    .font(Face.control.weight(.semibold))
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
            .font(Face.control)
            .padding(.vertical, Space.hair)
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
        HStack(alignment: .top, spacing: Space.step) {
            Image(systemName: isKeeper ? "star.fill" : "circle")
                .foregroundStyle(isKeeper
                                 ? Ink.green
                                 : Color.secondary.opacity(0.5))
                .padding(.top, Space.hair)
                .help(isKeeper ? "The copy to keep" : "A spare copy")

            VStack(alignment: .leading, spacing: Space.hair) {
                Text(item.sourceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(decision == .deleted)
                Text(item.relativePath)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: Space.step)

            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount ?? 0), countStyle: .file))
                .font(Face.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if decision == .deleted {
                Label("Trash", systemImage: "trash.fill")
                    .font(Face.caption)
                    .foregroundStyle(Ink.red)
            } else if !isKeeper {
                Button("Keep this one", action: keep)
                    .controlSize(.small)
                    .tip("Make this the copy the group keeps")
            }
        }
        .padding(.vertical, Space.tight)
        .opacity(decision == .deleted ? 0.55 : 1)
    }
}

// MARK: - Sidebar rail


/// What a run is doing, while it does it.
///
/// A view of its own so the numbers that move several times a second are watched by
/// something the size of this box rather than by the pane that holds every row.
struct BusyOverlay: View {
    var activity: Activity
    let scanning: Bool

    var body: some View {
        VStack(spacing: Space.step) {
            ProgressView().controlSize(.large)
            Text(scanning ? "Looking for PDFs" : "Processing files")
                .font(Face.headline)
            Text(scanning
                 ? "\(activity.found) found so far"
                 : "\(activity.done) of \(activity.total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(activity.current)
                .font(Face.mono)
                .foregroundStyle(.secondary)
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
/// Deliberately not `@Observable` and deliberately a reference type held in `@State`:
/// nothing here is tracked, which is what makes it safe to read and update from inside
/// `body`, and it survives the body passes that a value type would not.
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

/// Holds the last answer the shelf's grid gave for `runner.results` narrowed to
/// `visibleKeys`, keyed on the same signature as `VisibleFilter`. That signature already
/// carries `results` (`runner.resultsToken`), so anything that could move which items are
/// shown -- a new scan, a rename, a decision, the search box, a tag -- invalidates this
/// too.
final class ShownFilter {
    private var signature: VisibleFilter.Signature?
    private var cached: [Item] = []

    func items(matching new: VisibleFilter.Signature, compute: () -> [Item]) -> [Item] {
        if signature == new { return cached }
        let value = compute()
        signature = new
        cached = value
        return value
    }
}
