import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

struct ContentView: View {
    // Seeded empty on purpose: a real password does not belong in source. The sidebar
    // warns while the list is empty, and what you type is kept in UserDefaults.
    @AppStorage("passwords") private var passwordsText = ""
    @AppStorage("moveOriginals") private var moveOriginals = true
    @AppStorage("encryptOutput") private var encryptOutput = false
    /// Kept in memory only, and shared with the settings window rather than owned here.
    /// A password written into a preferences plist is not a password.
    @ObservedObject private var secret = SessionSecret.shared
    @AppStorage("backupFolderName") private var backupFolderName = defaultBackupFolderName
    @AppStorage("backupCustomPath") private var backupCustomPath = ""
    /// Deliberately not @AppStorage: a password does not belong in a preferences plist.
    @State private var choosingBackupFolder = false
    @State private var watcher: FolderWatcher?
    @StateObject private var palette = Palette()
    @AppStorage("useFolderNames") private var useFolderNames = true
    // On by default so a file nearly always ends up with a year in front of it.
    @AppStorage("useMetadataDate") private var useMetadataDate = true
    @AppStorage("useFileDate") private var useFileDate = false
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("ruleCasing") private var ruleCasing: NameRules.Casing = .lowercase
    @AppStorage("ruleSeparator") private var ruleSeparator: NameRules.Separator = .keep
    @AppStorage("ruleStripSymbols") private var ruleStripSymbols = false
    @AppStorage("ruleStripDiacritics") private var ruleStripDiacritics = false
    @AppStorage("ruleAsciiOnly") private var ruleAsciiOnly = false
    @AppStorage("ruleDropArticles") private var ruleDropArticles = false
    @AppStorage("ruleMaxLength") private var ruleMaxLength = 0
    @AppStorage("ruleDatePosition") private var ruleDatePosition: NameRules.DatePosition = .prefix
    @AppStorage("ruleDateFormat") private var ruleDateFormat: NameRules.DateFormat = .dashed
    /// The arrangeable pattern's own two fields. `elements` round-trips through the
    /// bracket text (NamePattern.text/init(parsing:)); maxTotalLength has no spelling in
    /// that grammar, so it needs a key of its own.
    @AppStorage("namePattern") private var namePatternText = ""
    @AppStorage("namePatternMaxLength") private var namePatternMaxLength = 0
    @State private var draggingElementIndex: Int?
    @State private var editingElementIndex: Int?

    @AppStorage("sources") private var storedSources = ""
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("watchSources") private var watchSources = true
    @AppStorage("viewMode") private var mode: ViewMode = .catalogue
    @AppStorage("aiModel") private var aiModel = "gpt-4o-mini"
    @AppStorage("aiBaseURL") var aiBaseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var aiUseEnvironment = true
    @AppStorage("autoIdentify") private var autoIdentify = false
    @AppStorage("bibLineWidth") private var bibLineWidth = 80
    @AppStorage("bibIndent") private var bibIndent = 2
    @AppStorage("bibAlign") private var bibAlign = true
    @AppStorage("bibDelimiter") private var bibDelimiter: BibStyle.Delimiter = .braces
    @AppStorage("bibTrailingComma") private var bibTrailingComma = true
    @AppStorage("bibBlankLines") private var bibBlankLines = true
    @AppStorage("bibSortFields") private var bibSortFields = false
    @AppStorage("bibDropAllCaps") private var bibDropAllCaps = false
    @AppStorage("bibOmitFile") private var bibOmitFile = true
    @AppStorage("bibType") private var bibType: BibType = .book
    @State private var availableModels: [String] = []
    @ObservedObject private var priceBook: PriceBook = .shared
    @ObservedObject private var spendSignal: SpendSignal = .shared
    @State var librarySummary: LibrarySummary?
    @State var libraryQuery = ""
    @State var libraryHits: [DocumentRecord]?
    @State var librarySearching = false
    @State var showingProjects = false
    @State private var sessionSpend: SpendTotals?
    @State private var loadingModels = false
    @State private var modelsError: String?

    @StateObject var runner = Runner()
    @StateObject private var covers = Covers()
    @State private var selection: [URL] = []
    @State private var importing = false
    /// Folders start closed. Only what has been opened, or opened for you to reach the
    /// selected file, is in here.
    @State private var tagCounts: [TagCount] = []
    @State private var renamingTag = false
    @State private var tagBeingRenamed: TagCount?
    @State private var renamedTagText = ""
    /// Rebuilt from the results whenever they change, so the Explorer draws a folder
    /// hierarchy without walking the disk again.
    @State private var explorerTree: [ExplorerNode] = []
    /// Which folders are open, by path. Kept here rather than inside `OutlineGroup` so the
    /// Explorer can be folded and unfolded from its header the way an editor's can.
    @State private var explorerExpanded: Set<String> = []
    @State private var explorerFilter = ""
    @State private var expanded: Set<String> = []
    @State private var sizedWindow = false
    @State private var confirmingApply = false
    @State private var reviewing: String?
    @FocusState private var focusedPassword: Int?
    @ObservedObject var chrome: Chrome

    private var passwords: [String] { PasswordList.active(passwordsText) }
    private var passwordRows: [String] { PasswordList.rows(passwordsText) }

    /// Adds a row and puts the caret in it, so Add is one click and then typing.
    private func addPassword() {
        let added = PasswordList.addingRow(to: passwordsText)
        passwordsText = added.text
        DispatchQueue.main.async { focusedPassword = added.focus }
    }

    private func passwordBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let rows = PasswordList.rows(self.passwordsText)
                return rows.indices.contains(index) ? rows[index] : ""
            },
            set: { self.passwordsText = PasswordList.setting(index, to: $0, in: self.passwordsText) }
        )
    }

    private var backup: BackupSettings {
        BackupSettings(
            enabled: moveOriginals,
            folderName: backupFolderName,
            customLocation: backupCustomPath.isEmpty ? nil : URL(fileURLWithPath: backupCustomPath)
        )
    }

    var aiClient: AIClient {
        AIClient(baseURL: aiBaseURL, model: aiModel,
                 apiKey: resolvedKey(useEnvironment: aiUseEnvironment))
    }

    private var aiReady: Bool { !aiClient.apiKey.isEmpty }

    /// The list is asked for once a key exists, and on demand after that.
    private func loadModels() {
        guard aiReady, !loadingModels else { return }
        loadingModels = true
        modelsError = nil
        let client = aiClient
        Task {
            do {
                availableModels = try await client.models()
            } catch {
                modelsError = error.localizedDescription
            }
            loadingModels = false
        }
    }

    private var rules: NameRules {
        NameRules(casing: ruleCasing, separator: ruleSeparator,
                  stripSymbols: ruleStripSymbols, stripDiacritics: ruleStripDiacritics,
                  asciiOnly: ruleAsciiOnly, dropLeadingArticles: ruleDropArticles,
                  maxLength: ruleMaxLength, datePosition: ruleDatePosition,
                  dateFormat: ruleDateFormat)
    }

    /// Runs once: a user who already had toggles set gets an arranged pattern that
    /// reproduces them, rather than landing on today's plain default and looking like
    /// their settings were dropped. After this the pattern is its own preference and the
    /// toggles it replaces (date position, date format, max length) are read here only.
    /// The handful of files the pattern editor previews against, handed to the window
    /// that shows it.
    private func publishNamingPreview() {
        NamingPreviewSource.shared.update(
            reference: reviewing.flatMap(runner.item) ?? runner.results.first,
            samples: Array(runner.results.prefix(5)),
            guesses: runner.guesses
        )
    }

    private func seedNamePatternIfNeeded() {
        guard UserDefaults.standard.string(forKey: "namePattern") == nil else { return }
        var date = NameToken(.date)
        if ruleDateFormat == .compact { date.abbreviation = .compact }
        var title = NameToken(.title)
        title.maxLength = ruleMaxLength
        let joiner = ruleSeparator == .underscore ? "_" : "-"
        let elements: [NameElement] = ruleDatePosition == .prefix
            ? [.token(date), .literal(joiner), .token(title)]
            : [.token(title), .literal(joiner), .token(date)]
        namePatternText = NamePattern(elements: elements).text
    }



    /// The pattern Plan and Apply actually use, or nil when there is none to use.
    ///
    /// An empty pattern is not an instruction to produce empty names — it is the absence
    /// of one, and the ordinary rename takes over.
    private var activePattern: NamePattern? {
        let parsed = NamePattern(parsing: namePatternText, maxTotalLength: namePatternMaxLength)
        return parsed.elements.isEmpty ? nil : parsed
    }

    private func options(dryRun: Bool) -> Options {
        // Subfolders are always included; the preview shows exactly what that reaches.
        Options(passwords: passwords, recursive: true, dryRun: dryRun,
                backup: backup,
                encryption: EncryptionSettings(enabled: encryptOutput, password: secret.encryptPassword),
                useFolderNames: useFolderNames,
                useMetadataDate: useMetadataDate, useFileDate: useFileDate, rules: rules,
                pattern: activePattern)
    }

    /// What only a fresh scan can answer: which files there are, and which of them open.
    /// Change one of these and the preview no longer describes reality, so Apply is
    /// blocked until Preview runs again.
    private var fingerprint: String {
        [
            selection.map(\.path).joined(separator: "|"),
            namePatternText, String(namePatternMaxLength),
            passwords.joined(separator: "|"),
            "\(moveOriginals)", backup.safeFolderName, backupCustomPath,
        ].joined(separator: "\u{1}")
    }

    /// What only changes the names. These are answered from dates already captured, so
    /// the list restyles itself instead of asking for another preview.
    private var namingFingerprint: String {
        [
            "\(useFolderNames)", "\(useMetadataDate)", "\(useFileDate)",
            ruleCasing.rawValue, ruleSeparator.rawValue,
            "\(ruleStripSymbols)", "\(ruleStripDiacritics)", "\(ruleAsciiOnly)",
            "\(ruleDropArticles)", "\(ruleMaxLength)",
            ruleDatePosition.rawValue, ruleDateFormat.rawValue,
        ].joined(separator: "\u{1}")
    }

    private var backupSummary: String {
        guard moveOriginals else {
            return "Originals are replaced in place. Nothing is kept and there is no undo."
        }
        if backupCustomPath.isEmpty {
            return "Moved to \(backup.safeFolderName)/ inside each source you pick, "
                 + "mirroring their subfolders."
        }
        return "Moved to the folder above, under one subfolder per source."
    }

    private var previewIsCurrent: Bool {
        !runner.results.isEmpty && runner.lastRunWasDry && runner.fingerprint == fingerprint
    }

    private func preview() {
        runner.preview(roots: selection, options: options(dryRun: true), fingerprint: fingerprint)
    }

    private func apply() {
        runner.apply(options: options(dryRun: false))
    }

    /// Anything irreversible gets a prompt: files headed for the Trash, or renames with
    /// no backup kept. A plain rename with backups on needs no ceremony.
    private func confirmApply() {
        if needsConfirmation { confirmingApply = true } else { apply() }
    }

    private var needsConfirmation: Bool {
        !moveOriginals || runner.deletedCount > 0
    }

    private var applyWarnings: [String] {
        var lines: [String] = []
        if runner.deletedCount > 0 {
            lines.append("\(runner.deletedCount) file\(runner.deletedCount == 1 ? "" : "s") "
                         + "will be moved to the Trash, recoverable from Finder.")
        }
        if !moveOriginals && runner.confirmedCount > 0 {
            lines.append("Move originals is off, so no copy of the other "
                         + "\(runner.confirmedCount) is kept. That cannot be undone.")
        }
        return lines
    }

    var body: some View {
        // The rail sits outside the split view on purpose: it is how every part of the app
        // is reached, and a NavigationSplitView on macOS collapses its own sidebar column,
        // and everything in it, once the window is too narrow for both columns. With the
        // rail inside that column the collapse took every way to reach another tab down
        // with the panel, and nothing short of widening the window brought it back. Beside
        // the split view instead, the panel still hides on a narrow window, as a sidebar
        // should, while the rail stays put.
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $chrome.columnVisibility) {
                sidebarPanel
                    .navigationSplitViewColumnWidth(min: Metric.sidebarMin, ideal: Metric.sidebarIdeal, max: Metric.sidebarMax)
            } detail: {
            ResultsPane(
                runner: runner,
                covers: covers,
                expanded: $expanded,
                selected: $reviewing,
                sourceCount: selection.count,
                previewIsCurrent: previewIsCurrent,
                passwords: passwords,
                reading: chrome.reading,
                watching: watchSources && !selection.isEmpty,
                palette: palette,
                rules: rules,
                chooseFiles: { importing = true },
                preview: preview,
                apply: confirmApply,
                applyOne: { item, name in
                    runner.applyNow(item, as: name, options: options(dryRun: false))
                }
            )
                // Derived from the same arithmetic `split` clamps the inspector with, so
                // this can no longer drift out of step with what the panes inside it
                // actually add up to. Grows with the notes rail and, since it is nested
                // inside the inspector, the contents rail.
                // One pane's floor, not two. The panel and the outline both fold inside
                // this region now, so the detail side no longer has to be wide enough for
                // panes that may not be drawn.
                .frame(minWidth: SplitLayout.detailMinWidth())
                // The title is the place and its counts, set by the pane that knows
                // which place that is.
                .toolbar { toolbar }
            }
            .navigationSplitViewStyle(.balanced)
        }

            // Everything transient goes here and only here, so the toolbar never changes
            // shape while work is running.
            Divider()
            StatusBar(
                runner: runner,
                watching: watchSources && !selection.isEmpty,
                sources: selection.count,
                spend: sessionSpendLabel,
                planIsCurrent: previewIsCurrent
            )
        }
        // 640 × 480. It was 1011 × 560, and 1252 wide the moment the notes were open,
        // because the rail, the notes rail and the contents rail were all fixed
        // neighbours the width arithmetic had to reserve for. Each of them folds now, so
        // the window's floor is a number the app chose rather than a sum it was handed.
        .frame(minWidth: Metric.windowFloorWidth, minHeight: Metric.windowFloorHeight)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .onChange(of: runner.canUndo) { _, can in chrome.canUndo = can }
        // The pattern editor lives in the settings window now and has no scanner of its
        // own, so the window that does have one publishes the few files it previews
        // against. Keyed on the results token rather than the array: this runs on every
        // change to a large collection and must not copy it to find out nothing moved.
        .onChange(of: runner.resultsToken, initial: true) { _, _ in publishNamingPreview() }
        .onChange(of: reviewing) { _, _ in publishNamingPreview() }
        .onAppear {
            seedNamePatternIfNeeded()
            chrome.undo = { runner.undo() }
            chrome.canUndo = runner.canUndo
            sizeWindowOnFirstLaunch()
            NSApp.appearance = appearance.nsAppearance
            restoreSources()
            startWatching()
            if !selection.isEmpty {
                // Show last time's answer at once, then check the disk behind it.
                let hadCache = runner.showCached(fingerprint: fingerprint)
                if autoPreview || hadCache { preview() }
            }
            if aiReady && availableModels.isEmpty { loadModels() }
        }
        .onChange(of: appearance) { _, new in NSApp.appearance = new.nsAppearance }
        // Restyling is cheap but not free, so let a run of toggles settle first.
        .task(id: namingFingerprint) {
            guard !runner.results.isEmpty, runner.lastRunWasDry else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            runner.restyle(options: options(dryRun: true))
        }
        .confirmationDialog("Apply to \(runner.actionable) files?", isPresented: $confirmingApply) {
            Button("Apply", role: .destructive, action: apply)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyWarnings.joined(separator: "\n\n"))
        }
        .fileImporter(
            isPresented: $choosingBackupFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { outcome in
            if case .success(let urls) = outcome, let folder = urls.first {
                backupCustomPath = folder.path
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .folder],
            allowsMultipleSelection: true
        ) { outcome in
            if case .success(let urls) = outcome { add(urls) }
        }
    }

    /// The session's spend for the status bar, or nil when nothing has been billed yet.
    ///
    /// Currencies are listed rather than added together, the same as everywhere else that
    /// shows money: a rate typed in for a provider that does not bill in dollars is not
    /// dollars, and a bar is no place to start pretending otherwise.
    private var sessionSpendLabel: String? {
        guard let sessionSpend, sessionSpend.calls > 0 else { return nil }
        guard !sessionSpend.byCurrency.isEmpty else {
            return "\(sessionSpend.calls) unpriced call\(sessionSpend.calls == 1 ? "" : "s")"
        }
        let amounts = sessionSpend.byCurrency.sorted { $0.key < $1.key }
            .map { $1.formatted(.currency(code: $0)) }
            .joined(separator: " + ")
        return "\(amounts) this session"
    }

    // MARK: Sidebar

    /// The panel behind the rail. Everything used to be one long scroll of nine sections;
    /// this shows one job at a time. The rail that switches between them is a sibling of
    /// this in `body`, not a parent of it.
    /// One list, in sections, rather than twelve tabs behind a rail.
    ///
    /// The rail existed because nine sections in a single scroll was too much to read;
    /// with everything you set once moved into the settings window, what is left is four
    /// things that are all navigation, and they belong on screen together. Sources first
    /// because it is where the files come from, the folder tree under it because that is
    /// the same question one level down.
    private var sidebarPanel: some View {
        // A sidebar, not a settings sheet. A grouped Form gives every section a white card
        // and a paragraph of explanation, which is right for the settings window and wrong
        // for the one column that answers "where am I": there the rows want to be small,
        // dense and close together.
        List {
            sourcesPanel
            explorerPanel
            tagsPanel
            libraryPanel
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity)
    }

    // Not private: SidebarTests renders this on its own, squeezed, to check that it holds
    // its width rather than being compressed away.
    // MARK: Tags

    @ViewBuilder
    private var tagsPanel: some View {
        Section {
            if Library.shared == nil {
                Text("The library is unavailable").foregroundStyle(.secondary)
            } else if tagCounts.isEmpty {
                Text("No tags yet").foregroundStyle(.secondary)
            } else {
                ForEach(tagCounts) { tag in
                    tagRow(tag)
                }
            }
        } header: {
            Text("Tags")
        }
        .task { await reloadTagCounts() }
        .alert("Rename Tag", isPresented: $renamingTag, presenting: tagBeingRenamed) { tag in
            TextField("Name", text: $renamedTagText)
            Button("Rename") { Task { await performRenameTag(tag) } }
            Button("Cancel", role: .cancel) {}
        } message: { tag in
            Text("Renaming \"\(tag.name)\" changes it everywhere it is used.")
        }
    }

    private func tagRow(_ tag: TagCount) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .showTagInCatalogue, object: nil, userInfo: ["tag": tag.name])
        } label: {
            HStack {
                Label(tag.name, systemImage: "tag")
                Spacer()
                Text("\(tag.documents)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .tip("Show the \(tag.documents) document\(tag.documents == 1 ? "" : "s") carrying this tag")
        .contextMenu {
            Button("Rename…") {
                tagBeingRenamed = tag
                renamedTagText = tag.name
                renamingTag = true
            }
            Button("Delete", role: .destructive) {
                Task { await performDeleteTag(tag) }
            }
        }
    }

    private func reloadTagCounts() async {
        guard let library = Library.shared else {
            tagCounts = []
            return
        }
        tagCounts = (try? await library.tagCounts()) ?? []
    }

    private func performRenameTag(_ tag: TagCount) async {
        guard let library = Library.shared else { return }
        let name = renamedTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != tag.name else { return }
        try? await library.renameTag(tag.name, to: name)
        await reloadTagCounts()
    }

    private func performDeleteTag(_ tag: TagCount) async {
        guard let library = Library.shared else { return }
        try? await library.deleteTag(tag.name)
        await reloadTagCounts()
    }

    // MARK: Explorer

    /// What the filter box leaves of the tree. Recomputed as it is typed rather than kept
    /// in state, so it can never disagree with the tree it is filtering.
    private var visibleExplorerTree: [ExplorerNode] {
        filterExplorerTree(explorerTree, matching: explorerFilter)
    }

    @ViewBuilder
    private var explorerPanel: some View {
        Section {
            if runner.results.isEmpty {
                Text("Nothing scanned yet").foregroundStyle(.secondary)
            } else {
                explorerFilterField
                let visible = visibleExplorerTree
                if visible.isEmpty {
                    Text("No file here matches \"\(explorerFilter)\"")
                        .foregroundStyle(.secondary)
                } else {
                    ExplorerOutline(
                        nodes: visible,
                        expanded: $explorerExpanded,
                        // A filter that hid its own matches inside folded folders would be
                        // useless, so filtering opens everything it kept and folding is
                        // handed back once the box is empty again.
                        forceExpanded: !explorerFilter.isEmpty,
                        selected: reviewing,
                        select: { reviewing = $0 }
                    )
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Explorer")
                Spacer()
                Button {
                    explorerExpanded = explorerFolderIDs(explorerTree)
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .disabled(runner.results.isEmpty || !explorerFilter.isEmpty)
                .tip("Unfold every folder")

                Button {
                    explorerExpanded = []
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.borderless)
                .disabled(runner.results.isEmpty || !explorerFilter.isEmpty)
                .tip("Fold every folder")
            }
        }
        .task(id: runner.results.count) {
            explorerTree = buildExplorerTree(runner.results)
            // The roots open on their own: a tree that arrives entirely folded says nothing
            // about what was just scanned. Anything folded by hand below them stays folded.
            explorerExpanded.formUnion(explorerTree.map(\.id))
        }
    }

    private var explorerFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter by name", text: $explorerFilter)
                .textFieldStyle(.plain)
            if !explorerFilter.isEmpty {
                Button { explorerFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .tip("Clear the filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var sourcesPanel: some View {
            Section("Sources") {
                if selection.isEmpty {
                    Text("Nothing selected")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(selection, id: \.self) { url in
                        SourceRow(url: url) { removeSource(url) }
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("Add folder or PDF", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                if !selection.isEmpty || !runner.results.isEmpty {
                    Button(role: .destructive, action: forgetEverything) {
                        Label("Forget sources and cached covers", systemImage: "trash")
                    }
                    .buttonStyle(.link)
                    .tip("Clears the selection, the results and the thumbnails")
                }
            }
    }




    @ViewBuilder
    private func refreshSessionSpend() async {
        guard let library = Library.shared else { return }
        guard let entries = try? await library.spendEntries(since: sessionStart) else { return }
        sessionSpend = spendTotals(for: entries)
    }

    /// What the chosen model costs, and what has been spent this session.
    ///
    /// An unknown price is said to be unknown. Showing nothing, or a zero, would read as
    /// free, and this app talks to any OpenAI-compatible endpoint, most of which this
    /// table has never heard of.
    @ViewBuilder private var modelPrice: some View {
        if let price = priceBook.table.price(model: aiModel, endpoint: aiBaseURL) {
            LabeledContent("Price") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(price.inputPerMillion.formatted(.currency(code: price.currency))) in")
                    Text("\(price.outputPerMillion.formatted(.currency(code: price.currency))) out")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .tip("Per million tokens. Recorded "
                 + price.recordedAt.formatted(date: .abbreviated, time: .omitted)
                 + ", and rates change.")
        } else {
            LabeledContent("Price") {
                Text("unknown")
                    .font(.caption)
                    .foregroundStyle(Ink.amber)
            }
            .tip("No price is known for this model at this endpoint. Calls are still "
                 + "recorded; set a rate in Settings to see what they cost.")
        }

        if let sessionSpend, sessionSpend.calls > 0 {
            LabeledContent("This session") {
                VStack(alignment: .trailing, spacing: 1) {
                    // Currencies are listed, never added together: a rate typed in for a
                    // provider that does not bill in dollars is not dollars.
                    Text(sessionSpend.byCurrency.isEmpty
                         ? "no priced calls"
                         : sessionSpend.byCurrency.sorted { $0.key < $1.key }
                             .map { $1.formatted(.currency(code: $0)) }.joined(separator: " + "))
                    Text("\(sessionSpend.calls) call\(sessionSpend.calls == 1 ? "" : "s")"
                         + (sessionSpend.callsWithUnknownCost > 0
                            ? ", \(sessionSpend.callsWithUnknownCost) unpriced" : ""))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .tip("What this run of the app has spent. Settings has the whole ledger.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .tip("Everything you set once, in a window of its own", key: "⌘,")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                chrome.reading.toggle()
            } label: {
                Label("Reading", systemImage: chrome.reading ? "book.fill" : "book")
            }
            .tip("Hide everything but the page", key: "⌘⇧R")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                chrome.inspectorCollapsed.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .tip("Info, rename, notes and the citation", key: "⌥⌘I")
        }

    }

    /// The selection is a set of non-overlapping roots: a folder absorbs anything already
    /// picked inside it, and nothing already covered is added twice.
    private func add(_ urls: [URL]) {
        let before = selection
        selection = mergedSources(selection, adding: urls)
        guard selection.map(\.path) != before.map(\.path) else { return }
        persistSources()
        startWatching()
        if autoPreview { preview() }
    }

    /// Removing a source takes its files with it, straight away.
    private func removeSource(_ url: URL) {
        selection.removeAll { $0 == url }
        persistSources()
        runner.removeSource(url, fingerprint: fingerprint)
        startWatching()
        expanded = []
        ensureSelectionAfterSourceChange()
    }

    private func ensureSelectionAfterSourceChange() {
        if selection.isEmpty {
            runner.reset()
            reviewing = nil
        } else if let current = reviewing, runner.item(current) == nil {
            reviewing = nil
        }
    }

    /// Watches whatever is selected, so files copied in while the app is open are picked
    /// up without being asked for.
    private func startWatching() {
        watcher?.stop()
        guard watchSources, !selection.isEmpty else {
            watcher = nil
            return
        }
        let created = FolderWatcher { Task { @MainActor in await absorbChanges() } }
        created.watch(selection)
        watcher = created
    }

    private func absorbChanges() async {
        guard watchSources, !selection.isEmpty else { return }
        await runner.absorbChanges(roots: selection, options: options(dryRun: true),
                                   fingerprint: fingerprint)
    }

    private func persistSources() {
        storedSources = selection.map(\.path).joined(separator: "\n")
    }

    /// Restores what was picked last time. Anything since moved or deleted is dropped
    /// rather than kept as a broken row.
    private func restoreSources() {
        guard selection.isEmpty else { return }
        let paths = storedSources.split(separator: "\n").map(String.init)
        selection = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if selection.map(\.path) != paths { persistSources() }
    }

    /// Everything the app remembers between launches.
    private func forgetEverything() {
        selection = []
        storedSources = ""
        expanded = []
        reviewing = nil
        runner.reset()
        covers.forget()
    }

    /// The results list is greedy, which makes `.defaultSize` lose and the window open at
    /// min-width by full-screen-height. Set the frame directly instead, and only when
    /// AppKit has no autosaved one, so a resize the user made still wins next launch.
    private func sizeWindowOnFirstLaunch() {
        guard !sizedWindow else { return }
        sizedWindow = true
        guard UserDefaults.standard.object(forKey: "NSWindow Frame main") == nil,
              let window = NSApp.windows.first else { return }
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
    }
}

// MARK: - Sidebar pieces

struct SourceRow: View {
    let url: URL
    let remove: () -> Void

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .tip("Stop working on this source")
            .help("Remove this source")
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
    }
}

// MARK: - Naming pattern chips

/// Wraps chips onto as many lines as the sidebar's width needs, the same idea as a
/// browser's tag field: fixed-size pieces that flow rather than one row that clips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Reorders the pattern's elements as a chip is dragged over its neighbours, the same
/// immediate feedback a `List`'s own drag-to-reorder gives.
struct ChipDropDelegate: DropDelegate {
    let index: Int
    @Binding var draggingIndex: Int?
    let reorder: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let from = draggingIndex, from != index else { return }
        reorder(from, index)
        draggingIndex = index
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingIndex = nil
        return true
    }
}

struct Note: View {
    let icon: String
    let tint: Color
    let text: String
    var size: Font = .callout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
        }
        .font(size)
        .foregroundStyle(tint == .secondary ? .secondary : .primary)
    }
}

// MARK: - Results

// MARK: - Explorer tree

/// A folder or file in the current results, for the Explorer tab. Keyed by a real URL
/// rather than the results tree's synthetic node ids (`buildTree(_:)` in PDFHammerCore
/// names a node after its path components, not the path itself), since offering to open a
/// folder in the catalogue needs a path that actually exists on disk.
struct ExplorerNode: Identifiable {
    let id: String
    let name: String
    let url: URL
    /// `Item.key`, or nil for a folder.
    let itemKey: String?
    var children: [ExplorerNode]?
}

/// Groups the current results into the same folder hierarchy the results view builds,
/// keeping the real URL at every folder along the way.
func buildExplorerTree(_ items: [Item]) -> [ExplorerNode] {
    final class Builder {
        let name: String
        let url: URL
        var order: [String] = []
        var children: [String: Builder] = [:]
        var itemKey: String?
        init(name: String, url: URL) {
            self.name = name
            self.url = url
        }

        func child(_ key: String, name: String, url: URL) -> Builder {
            if let existing = children[key] { return existing }
            let made = Builder(name: name, url: url)
            children[key] = made
            order.append(key)
            return made
        }

        func node() -> ExplorerNode {
            guard itemKey == nil else {
                return ExplorerNode(id: itemKey!, name: name, url: url, itemKey: itemKey, children: nil)
            }
            // Folders first, then alphabetical, the way Finder lists a folder.
            let sortedChildren = order.map { children[$0]! }.sorted { lhs, rhs in
                if (lhs.itemKey == nil) != (rhs.itemKey == nil) { return lhs.itemKey == nil }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ExplorerNode(id: url.path, name: name, url: url, itemKey: nil,
                                children: sortedChildren.map { $0.node() })
        }
    }

    let top = Builder(name: "", url: URL(fileURLWithPath: "/"))
    for item in items {
        var cursor = top.child(item.root.path, name: item.root.lastPathComponent, url: item.root)
        var url = item.root
        for folder in item.relativePath.split(separator: "/").map(String.init).dropLast() {
            url.appendPathComponent(folder)
            cursor = cursor.child(url.path, name: folder, url: url)
        }
        let fileURL = item.currentURL
        let leaf = cursor.child(item.key, name: fileURL.lastPathComponent, url: fileURL)
        leaf.itemKey = item.key
    }
    return top.order.map { top.children[$0]!.node() }
}

/// The Explorer's tree, folded and unfolded from the outside.
///
/// `OutlineGroup` keeps its own expansion state where nothing can reach it, which is fine
/// until a header offers "unfold everything" or a filter has to open what it kept. Plain
/// `DisclosureGroup`s over a shared set of open folder paths put that state somewhere both
/// can act on.
struct ExplorerOutline: View {
    let nodes: [ExplorerNode]
    @Binding var expanded: Set<String>
    /// Overrides the set while a filter is on: everything shown is open, and folding it by
    /// hand meanwhile is not offered rather than silently ignored.
    let forceExpanded: Bool
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: binding(for: node)) {
                    ExplorerOutline(nodes: children, expanded: $expanded,
                                    forceExpanded: forceExpanded,
                                    selected: selected, select: select)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }

    private func binding(for node: ExplorerNode) -> Binding<Bool> {
        Binding(
            get: { forceExpanded || expanded.contains(node.id) },
            set: { open in
                guard !forceExpanded else { return }
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
    }

    private func row(_ node: ExplorerNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.itemKey == nil ? "folder" : "doc")
                .foregroundStyle(node.itemKey == nil ? Color.accentColor : .secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(
            node.itemKey != nil && node.itemKey == selected
                ? Color.accentColor.opacity(0.15) : .clear
        )
        .onTapGesture {
            guard let key = node.itemKey else { return }
            select(key)
        }
        .contextMenu {
            if node.itemKey == nil {
                // The catalogue is the only thing that can honour this, and it owns its own
                // state, so the intent is posted rather than reached for directly.
                Button("Open in Catalogue") {
                    NotificationCenter.default.post(
                        name: .openFolderInCatalogue, object: nil,
                        userInfo: ["path": node.url.path])
                }
            }
        }
    }
}

/// Every folder in the tree, for "unfold everything". Files are left out: they have nothing
/// to unfold, and a set carrying them would claim folders that do not exist.
func explorerFolderIDs(_ nodes: [ExplorerNode]) -> Set<String> {
    var found: Set<String> = []
    for node in nodes {
        guard let children = node.children else { continue }
        found.insert(node.id)
        found.formUnion(explorerFolderIDs(children))
    }
    return found
}

/// The tree with only what matches `query` left in it, plus the folders needed to reach it.
///
/// A folder whose own name matches keeps everything under it, the way typing a folder name
/// into an editor's explorer shows you that folder's contents rather than an empty branch.
/// Matching is `localizedStandardContains`, so it ignores case and diacritics the same way
/// the rest of the app's searching does.
func filterExplorerTree(_ nodes: [ExplorerNode], matching query: String) -> [ExplorerNode] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return nodes }

    return nodes.compactMap { node in
        let matches = node.name.localizedStandardContains(needle)
        guard let children = node.children else { return matches ? node : nil }
        if matches { return node }
        let kept = filterExplorerTree(children, matching: needle)
        guard !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        return copy
    }
}

/// The rail's width, shared by the rail itself and the window's minimum, so the two cannot
/// drift apart. Fixed rather than flexible: it holds while the panel beside it collapses.

// MARK: - Shortcuts

/// Every key in one place, reachable with ? so it does not have to be remembered or
/// looked up outside the app.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Deciding", [
            ("Return  C", "confirm the name and go to the next file"),
            ("E", "edit the name; Escape leaves the field"),
            ("G", "ask the model for a name"),
            ("B", "copy this file's BibTeX entry"),
            ("A", "apply this one file now"),
            ("S", "leave this file alone"),
            ("F", "leave the rest of this folder alone"),
            ("M", "move to another folder"),
            ("D", "move to the Trash on apply"),
            ("R", "reopen a decided file"),
        ]),
        ("Moving", [
            ("J  N  ↓", "next file; in the catalogue ↓ moves a whole row"),
            ("K  P  ↑", "previous file"),
            ("→  ←", "neighbour in the catalogue"),
        ]),
        ("Everything else", [
            ("⌘1 … ⌘4", "list, catalogue, BibTeX, duplicates"),
            ("⌘P", "plan"),
            ("⌘Return", "apply the reviewed plan"),
            ("⌘⇧Return", "confirm everything still pending"),
            ("⌘D", "find duplicates"),
            ("⌘R", "reveal in Finder"),
            ("O", "open in the default PDF viewer"),
            ("⌘Z", "undo the last decision"),
            ("⌘B", "show or hide the sidebar"),
            ("⌘⇧R", "reading mode: just the page"),
            ("⌘⇧N", "show or hide the notes beside the page"),
            ("⌘⇧T", "show or hide the table of contents"),
            ("?", "this list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(rows, id: \.0) { key, meaning in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(key)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 110, alignment: .leading)
                                    Text(meaning)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    Text("Letters work whenever the name field is not focused. Anything with "
                         + "Command works regardless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 560)
    }
}
