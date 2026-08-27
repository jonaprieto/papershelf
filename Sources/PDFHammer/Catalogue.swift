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
    @AppStorage("sortDescending") private var sortDescending = false
    /// Kept in step with the grid so the arrow keys can move by a row.
    @State private var gridColumns = 1
    @State private var showingShortcuts = false
    @StateObject private var converting = Converting()
    @State private var showingMarkdown = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var confirmingBatchAI = false
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 460
    @AppStorage("notesShown") private var notesShown = false
    @StateObject private var annotator = Annotator()
    @State private var addingNote = false
    @State private var noteText = ""

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

    private var selectedItem: Item? {
        runner.results.first { $0.key == selected }
    }

    /// What the views show: everything, or only what the query matched.
    private var shown: [Item] {
        guard let keys = runner.matchingKeys else { return runner.results }
        return runner.results.filter { keys.contains($0.key) }
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
        Group {
            if runner.busy {
                busyState
            } else if runner.results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if !reading {
                        summaryBar
                        Divider()
                    }
                    split
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !reading {
                        Divider()
                        StatusStrip(runner: runner, watching: watching)
                    }
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
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
            .sheet(isPresented: $showingMarkdown) {
                if let item = selectedItem {
                    MarkdownSheet(item: item, passwords: passwords, converting: converting)
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
            Button("OK") { runner.aiError = nil }
        } message: {
            Text(runner.aiError ?? "")
        }
    }

    /// Hoisted out of the modifier chain: an inline Binding there pushed the whole body
    /// past what the type-checker will work through.
    private var aiErrorShown: Binding<Bool> {
        Binding(get: { runner.aiError != nil }, set: { if !$0 { runner.aiError = nil } })
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

    private func handle(_ event: NSEvent) -> Bool {
        guard !runner.busy, !runner.results.isEmpty, selectedItem != nil else { return false }
        // Command combinations first: these are app-level and must work wherever focus is,
        // including while a name is being typed.
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "1": mode = .list; return true
            case "2": mode = .catalogue; return true
            case "3": mode = .bibliography; return true
            case "4": mode = .duplicates; return true
            case "r": revealInFinder(); return true
            case "d": runner.findDuplicates(passwords: passwords); return true
            case "\r" where event.modifierFlags.contains(.shift):
                runner.confirmAllPending()
                ensureSelection()
                return true
            default: return false
            }
        }
        guard event.modifierFlags.intersection([.option, .control]).isEmpty else { return false }

        // Anything being typed into, or any control that has its own idea of what a key
        // means, keeps the event. A table view does not: its type-select is what we are
        // deliberately replacing.
        if searchFocused { return false }
        if let responder = event.window?.firstResponder,
           responder is NSTextView || (responder is NSControl && !(responder is NSTableView)) {
            return false
        }

        // The lists are table views and move themselves; the catalogue is a grid and has
        // no such thing, so the arrows are handled here when a table is not in charge.
        let onATable = event.window?.firstResponder is NSTableView
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
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\r", "c": confirm()
        case "e": editingName = true
        case "s": skip()
        case "f": skipFolder()
        case "a": applyNow()
        case "g": identifySelected()
        case "m": choosingMoveTarget = true
        case "o": openInViewer()
        case "b": copyCitation()
        case "?": showingShortcuts = true
        case "/": searchFocused = true
        case "d": markDeleted()
        case "r": reopenSelected()
        case "j", "n": step(by: 1)
        case "k", "p": step(by: -1)
        default: return false
        }
        return true
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
              runner.guesses[item.key] == nil,
              !runner.isThinking(item)
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
               aiReady, runner.guesses[item.key] == nil {
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
            if bibShowsFile {
                BibFileView(entries: runner.bib, order: $bibOrder, completeOnly: $bibCompleteOnly,
                            style: bibStyle)
            } else {
                bibEntryList
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
            .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
            .disabled(runner.identicalExtras == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var bibDocument: String {
        bibtexDocument(runner.bib, includeIncomplete: !bibCompleteOnly, order: bibOrder)
    }

    private var bibBar: some View {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
            let incomplete = runner.bib.filter { !$0.isComplete }.count
            Text("\(runner.bib.count) entries").font(.callout).foregroundStyle(.secondary)
            if incomplete > 0 {
                Label("\(incomplete) incomplete", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
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
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: layout, alignment: .leading, spacing: 18) {
                    ForEach(runner.results) { item in
                        CoverCard(
                            item: item,
                            decision: runner.decision(for: item),
                            duplicate: runner.duplicateKind[item.key],
                            passwords: passwords,
                            covers: covers,
                            isSelected: selected == item.key
                        )
                        .id(item.key)
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
    /// Two panes with a divider the user owns. `HSplitView` renegotiates its own widths
    /// whenever its children change, which is why the inspector kept jumping; here the
    /// width only ever changes because someone dragged it, and it is remembered.
    private var split: some View {
        GeometryReader { geometry in
            let maximum = max(360, geometry.size.width - 360)
            let width = min(max(inspectorWidth, 360), maximum)
            HStack(spacing: 0) {
                // Reading gives the whole window to the page.
                if !reading {
                    browser.frame(maxWidth: .infinity, maxHeight: .infinity)
                    divider(width: width, maximum: maximum)
                }
                inspector
                    .frame(width: reading ? nil : width)
                    .frame(maxWidth: reading ? .infinity : nil, maxHeight: .infinity)
                if notesShown {
                    Divider()
                    NotesRail(annotator: annotator, palette: palette,
                              addingNote: $addingNote, noteText: $noteText,
                              lastColour: (palette.styles.first ?? Palette.defaults[0]).nsColor,
                              title: selectedItem?.destinationName ?? "Notes",
                              source: selectedItem?.currentURL.path ?? "",
                              close: { withAnimation(.easeOut(duration: 0.15)) { notesShown = false } })
                        .frame(width: 240)
                }
            }
        }
    }

    private func divider(width: CGFloat, maximum: CGFloat) -> some View {
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
                                inspectorWidth = min(max(width - value.translation.width, 360), maximum)
                            }
                    )
            }
    }

    private var list: some View {
        ScrollViewReader { scroll in
            List(selection: $selected) {
                ForEach(runner.tree) { node in
                    NodeView(node: node, expanded: $expanded, runner: runner,
                             menu: fileMenu, visible: runner.matchingKeys)
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
    private var inspector: some View {
        if let item = selectedItem {
            ReviewInspector(
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
                autoIdentify: $autoIdentify,
                reveal: revealInFinder,
                openExternally: openInViewer,
                moveTo: { choosingMoveTarget = true },
                aiReady: aiReady,
                markDeleted: markDeleted,
                reopen: reopenSelected,
                reset: { draft = item.destinationName },
                leaveField: { editingName = false; listFocused = true },
                excerpt: runner.excerpt(for: item),
                reading: reading,
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

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
              HStack(spacing: 10) {
                searchField
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tip("Which view of the same files", key: "⌘1 to ⌘4")

                ForEach(runner.statusCounts, id: \.0) { status, count in
                    StatusPill(status: status, count: count)
                }
                Spacer(minLength: 8)
                stateLabel
                    .lineLimit(1)
                    .fixedSize()
              }
              .padding(.trailing, 2)
            }
            .scrollIndicators(.hidden)

            if runner.lastRunWasDry {
              ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ProgressView(value: Double(runner.reviewed),
                                 total: Double(max(runner.results.count, 1)))
                        .frame(width: 140)
                    if let keys = runner.matchingKeys {
                        Text("\(keys.count) of \(runner.results.count) shown")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(keys.isEmpty
                                             ? Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
                                             : .secondary)
                    } else if runner.pendingCount == 0 {
                        Label("All \(runner.results.count) reviewed", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    } else {
                        Text("\(runner.reviewed) of \(runner.results.count) reviewed")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ItemSort.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 150)
                    .help("Reorders within each folder, and across the catalogue")
                    Button {
                        sortDescending.toggle()
                    } label: {
                        Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                    }
                    .controlSize(.small)
                    .tip(sortDescending ? "Largest or newest first" : "Smallest or oldest first")
                    .help(sortDescending ? "Largest or newest first" : "Smallest or oldest first")

                    duplicateControls
                    if aiReady && runner.pendingCount > 0 {
                        Button("Ask AI for \(runner.pendingCount)") { confirmingBatchAI = true }
                            .controlSize(.small)
                            .tip("One billed request per file still waiting")
                    }
                    Menu {
                        Button("Catalogue as Markdown") {
                            copyText(markdownCatalogue(runner.results, known: runner.guesses))
                        }
                        Button("Bibliography as Markdown") {
                            runner.ensureBib()
                            copyText(markdownBibliography(runner.bib))
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                    .tip("Copy the list or the bibliography as Markdown")

                    Button("Confirm all remaining") {
                        runner.confirmAllPending()
                        ensureSelection()
                    }
                    .controlSize(.small)
                    .tip("Accept every suggestion still waiting", key: "⌘⇧Return")
                    .disabled(runner.pendingCount == 0)
                }
                .padding(.trailing, 2)
              }
              .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // A bar keeps its natural height. Without this it absorbs whatever room the panes
        // below leave, and everything inside it stretches to match.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { runner.search(query, passwords: passwords) }
                .onChange(of: query) { _, new in
                    // Metadata is instant; a text query waits for Return so a shelf is
                    // not read from end to end on every keystroke.
                    if new.isEmpty || !Query(new).needsText {
                        runner.search(new, passwords: passwords)
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

    @ViewBuilder
    private var stateLabel: some View {
        if !runner.lastRunWasDry {
            Label("Applied, files on disk have changed", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        } else if !previewIsCurrent {
            Label("Settings changed, preview again", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
        } else if runner.showingCached {
            Label("From last time, rechecking the disk", systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if runner.appliedCount > 0 {
            Label("\(runner.appliedCount) applied so far, the rest is still a preview",
                  systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        } else {
            Label("Preview only, nothing has changed on disk", systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var busyState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text(runner.phase == .scanning ? "Looking for PDFs" : "Processing files")
                .font(.headline)
            Text(runner.phase == .scanning
                 ? "\(runner.found) found so far"
                 : "\(runner.done) of \(runner.total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(runner.current)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 480)
                .opacity(runner.current.isEmpty ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(hasSources ? "Ready to run" : "Nothing selected yet",
                  systemImage: hasSources ? "wand.and.sparkles" : "tray.and.arrow.down")
        } description: {
            Text(hasSources
                 ? "\(sourceCount) source\(sourceCount == 1 ? "" : "s") queued. Preview first, then apply."
                 : "Drop folders or PDFs anywhere in this window.")
        } actions: {
            if hasSources {
                Button("Preview", action: preview).buttonStyle(.borderedProminent)
            } else {
                Button("Choose Files or Folders…", action: chooseFiles)
                    .buttonStyle(.borderedProminent)
            }
        }
        // The whole empty pane is the target, not just the button.
        .contentShape(Rectangle())
        .onTapGesture { if !hasSources { chooseFiles() } }
    }
}

// MARK: - Review inspector

struct NodeView: View {
    let node: Node
    @Binding var expanded: Set<String>
    @ObservedObject var runner: Runner
    var menu: (Item) -> FileContextMenu = { item in
        FileContextMenu(item: item, confirm: {}, identify: {}, moveTo: {}, trash: {},
                        skip: {}, convert: {})
    }
    /// Nil means no filter. A folder with nothing visible under it disappears too.
    var visible: Set<String>?

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
        } else if let key = node.itemKey, let item = runner.item(key) {
            ResultRow(item: item, decision: runner.decision(for: item),
                      duplicate: runner.duplicateKind[item.key])
                .tag(key)
                .id(key)
                .contextMenu { menu(item) }
                // A real file drag: Finder and anything else that takes one gets a copy.
                .onDrag { NSItemProvider(contentsOf: item.currentURL) ?? NSItemProvider() }
        } else {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    NodeView(node: child, expanded: $expanded, runner: runner,
                             menu: menu, visible: visible)
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
        }
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
                        .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
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

    @ViewBuilder
    private var reviewMark: some View {
        markGlyph.tip(decision?.explanation ?? undecidedExplanation)
    }

    @ViewBuilder
    private var markGlyph: some View {
        switch decision {
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .applied:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
        case .deleted:
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
        case .moveTo:
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
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

    private var name: String {
        if case .confirmed(let confirmed) = decision { return confirmed }
        return item.destinationName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary.opacity(0.5))
                // Touching `revision` is what redraws this card when its render lands.
                let _ = covers.revision
                if let cover = covers.cover(for: item, passwords: passwords, height: 320) {
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
            .frame(height: 168)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { badges }

            Text(name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .foregroundStyle(decision == .deleted ? .secondary : .primary)
                .strikethrough(decision == .deleted)
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
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
            case .applied: Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            case .deleted: Image(systemName: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
            case .moveTo: Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
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
        .background(color.opacity(0.16), in: Capsule())
        // A Capsule fills whatever height it is handed; without this the pill grows into
        // any spare room its row is given.
        .fixedSize()
        .tip(status.explanation)
    }

    private var icon: String {
        switch status {
        case .decrypted: return "lock.open.fill"
        case .renamed: return "textformat"
        case .locked: return "lock.fill"
        case .trashed: return "trash.fill"
        case .moved: return "arrow.right.doc.on.clipboard"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// System greens and oranges sit around 2:1 on a light background, which is
    /// unreadable at caption size. These are darkened for light and lifted for dark.
    private var color: Color {
        switch status {
        case .decrypted: return Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
        case .renamed:   return Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
        case .locked:    return Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
        case .trashed:   return Color(light: srgb(88, 88, 96), dark: srgb(178, 178, 190))
        case .moved:     return Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
        case .failed:    return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
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
                .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
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
    case .identical: return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
    case .sameText: return Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
    case .likely: return Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
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
                                 ? Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
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
                    .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
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
