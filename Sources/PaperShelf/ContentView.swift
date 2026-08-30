import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PaperShelfCore

struct ContentView: View {
    private enum SidebarTarget: Hashable {
        case shelf(SmartList)
        case source(String)
        case folder(String)
        case document(String)
        case project(Int64)
        case tag(String)
        case addSource
    }

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
    /// Which Markdown converter a project reads its documents with, chosen in Settings.
    @AppStorage("defaultConverter") private var defaultConverter = ""
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
    @ObservedObject private var shelves: Shelves = .shared
    @ObservedObject private var libraryStatus: LibraryStatus = .shared
    @State private var projects: [ProjectSummary] = []
    @State private var namingProject = false
    /// The source row under the pointer, so its remove button is only there when it is
    /// being looked at.
    @State private var hoveredSource: URL?
    @State private var newProjectName = ""
    /// The project being read, if any. It takes the middle of the window, the way a
    /// document does.
    @State private var openProject: ProjectSummary?
    @State private var sessionSpend: SpendTotals?
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var sourceAvailability: [String: Bool] = [:]
    /// When the selected document was last opened, for the status bar. Read from the
    /// library rather than kept in memory: the answer outlives the session that set it.
    @State private var selectionOpenedAt: Date?

    @StateObject var runner = Runner()
    @StateObject private var covers = Covers()
    /// The page on screen. Held by the window because the status bar, which is outside
    /// the results pane, says what is on it.
    @StateObject private var annotator = Annotator()
    @State private var selection: [URL] = []
    @State private var sidebarTarget: SidebarTarget?
    /// The project row a drag is currently over, so exactly one row lights up.
    @State private var dropProject: Int64?
    @State private var importing = false
    /// Folders start closed. Only what has been opened, or opened for you to reach the
    /// selected file, is in here.
    @State private var tagCounts: [TagCount] = []
    @State private var renamingTag = false
    @State private var tagBeingRenamed: TagCount?
    @State private var renamedTagText = ""
    @State private var deletingTag = false
    @State private var tagBeingDeleted: TagCount?
    /// Rebuilt from the results whenever they change, so the Explorer draws a folder
    /// hierarchy without walking the disk again.
    /// Bumped whenever something outside the project workspace changes what an open
    /// project holds, so the workspace reads its members again.
    @State private var projectContentsRevision = 0
    @State private var explorerTree: [ExplorerNode] = []
    /// Narrows the source tree to folders whose name matches. `filterExplorerTree` was
    /// written and tested and then reached by nothing; the sidebar's own footer is where
    /// a filter for the sidebar belongs.
    @State private var sourceFilter = ""
    @State private var filteringSources = false
    /// Which folders are open, by path. Kept here rather than inside `OutlineGroup` so the
    /// Explorer can be folded and unfolded from its header the way an editor's can.
    @State private var explorerExpanded: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var sizedWindow = false
    @State private var confirmingApply = false
    @State private var reviewing: String?
    @FocusState private var focusedPassword: Int?
    @FocusState private var sidebarFocused: Bool
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
            guesses: runner.ai.guesses
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

    /// Reads the sources again from scratch, whatever is on screen: the shelf if that is
    /// what you are looking at, the full plan if you were reviewing names. Covers are
    /// dropped with it, since a file that changed on disk has a cover that no longer
    /// describes it.
    private func forceRefresh() {
        guard !selection.isEmpty else { return }
        covers.forget()
        if mode == .catalogue { libraryPreview() } else { preview() }
    }

    private func libraryPreview() {
        runner.libraryPreview(roots: selection, options: options(dryRun: true), fingerprint: fingerprint)
    }

    private func libraryPreview(preservingVisibleResults: Bool) {
        runner.libraryPreview(roots: selection, options: options(dryRun: true),
                              fingerprint: fingerprint,
                              preservingVisibleResults: preservingVisibleResults)
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
                    .region(.sidebar)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($sidebarFocused)
                    .navigationSplitViewColumnWidth(min: Metric.sidebarMin, ideal: Metric.sidebarIdeal, max: Metric.sidebarMax)
            } detail: {
            if let openProject, let library = Library.shared {
                ProjectWorkspace(
                    project: openProject,
                    env: liveProjectsEnvironment(library: library, client: aiClient,
                                                 endpoint: aiBaseURL, model: aiModel,
                                                 passwords: { passwords },
                                                 converterName: { defaultConverter }),
                    membershipChanged: { Task { await reloadProjects() } },
                    reloadToken: projectContentsRevision,
                    close: {
                        self.openProject = nil
                        sidebarTarget = .shelf(shelves.current)
                    }
                )
                .frame(minWidth: SplitLayout.detailMinWidth())
            } else {
            ResultsPane(
                runner: runner,
                covers: covers,
                expanded: $expanded,
                selected: $reviewing,
                sourceCount: selection.count,
                unavailableSourceCount: selection.filter { !isReachable($0) }.count,
                previewIsCurrent: previewIsCurrent,
                passwords: passwords,
                reading: chrome.reading,
                setReading: chrome.setReading,
                watching: watchSources && !selection.isEmpty,
                palette: palette,
                annotator: annotator,
                rules: rules,
                chooseFiles: { importing = true },
                focusSidebar: {
                    chrome.columnVisibility = .all
                    sidebarFocused = true
                    sidebarTarget = .shelf(shelves.current)
                },
                handleSidebarKey: handleSidebarKey,
                preview: preview,
                refresh: forceRefresh,
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
                // The toolbar belongs to the pane that knows what is in it: the views,
                // the search, the actions for this view, and the two chrome toggles, in
                // that order. The title is the place and its counts, set there too.
            }
            }
            .navigationSplitViewStyle(.balanced)
        }

            // Everything transient goes here and only here, so the toolbar never changes
            // shape while work is running.
            Divider()
            statusBar
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
        // Sources can be added in Settings › General as well as here, and both write the
        // same preference. Following it means the two lists cannot disagree about what is
        // being scanned.
        .onChange(of: storedSources) { _, stored in
            let wanted = stored.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            guard wanted.map(\.path) != selection.map(\.path) else { return }
            selection = wanted.filter { FileManager.default.fileExists(atPath: $0.path) }
            startWatching()
            ensureSelectionAfterSourceChange()
            if !selection.isEmpty { mode == .catalogue ? libraryPreview() : preview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProject), perform: revealProject)
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
                if autoPreview || hadCache {
                    if mode == .catalogue {
                        libraryPreview(preservingVisibleResults: hadCache)
                    } else {
                        preview()
                    }
                }
            }
            if aiReady && availableModels.isEmpty { loadModels() }
        }
        .onChange(of: appearance) { _, new in NSApp.appearance = new.nsAppearance }
        .task { await watchSourceAvailability() }
        .task(id: reviewing) { await readSelectionPosition() }
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
        VStack(spacing: 0) {
            List {
                shelvesPanel
                // Sources above projects: where the files came from is the question asked
                // of a sidebar far more often than which piece of work they are for, and
                // the four section headers are what separate them. There were rules
                // between them; whitespace and a small caps heading do that job without
                // drawing three more lines down a column that is already a list of lists.
                sourcesPanel
                projectsPanel
                tagsPanel
            }
            .listStyle(.sidebar)
            .listRowSeparator(.hidden)
            sidebarFooter
        }
        .frame(maxWidth: .infinity)
    }

    /// One row of the sidebar: something you can go to, and how much is there.
    ///
    /// Written once because four sections were each drawing their own, and they disagreed
    /// -- one count was 11 points and the next 13, and a chosen row was accent-coloured
    /// text in one section and a tinted background in another. Selected is the platform's
    /// own answer: a filled bar with the label on it.
    private func sidebarRow<Label: View, Trailing: View>(
        _ selected: Bool,
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            label()
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
                .monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8))
                                          : AnyShapeStyle(.secondary))
        }
        .font(Face.body)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: Metric.control))
    }

    /// What the sidebar can be told to do, under what it is showing: add a source, narrow
    /// the tree, and how many sources there are.
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            if filteringSources {
                TextField("Filter folders", text: $sourceFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onExitCommand { sourceFilter = ""; filteringSources = false }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            HStack(spacing: 10) {
                Button { importing = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .tip("Watch another folder, or add one PDF")

                Button {
                    filteringSources.toggle()
                    if !filteringSources { sourceFilter = "" }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(filteringSources ? Color.accentColor : .secondary)
                .tip("Show only folders whose name matches")

                Spacer(minLength: 6)

                Text("\(selection.count) source\(selection.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(Face.control)
            .padding(.horizontal, 10)
            .frame(height: Metric.statusBar)
        }
    }

    private var sidebarTargets: [SidebarTarget] {
        var targets = SmartList.allCases.map(SidebarTarget.shelf)
        for source in selection {
            targets.append(.source(source.path))
            if let root = explorerTree.first(where: { $0.url == source }),
               let children = root.children, explorerExpanded.contains(root.id) {
                appendSidebarTargets(children, to: &targets)
            }
        }
        targets += projects.map { .project($0.id) }
        targets += tagCounts.map { .tag($0.name) }
        targets.append(.addSource)
        return targets
    }

    private var focusedSidebarPath: String? {
        switch sidebarTarget {
        case .source(let path), .folder(let path): return path
        case .document(let key): return runner.item(key)?.currentURL.path ?? key
        default: return nil
        }
    }

    private func appendSidebarTargets(_ nodes: [ExplorerNode], to targets: inout [SidebarTarget]) {
        for node in nodes {
            if let key = node.itemKey {
                targets.append(.document(key))
            } else {
                targets.append(.folder(node.url.path))
                if let children = node.children, explorerExpanded.contains(node.id) {
                    appendSidebarTargets(children, to: &targets)
                }
            }
        }
    }

    /// The sidebar's rows are SwiftUI buttons and outline labels, not one native table
    /// selection. Keep a small model for arrows/Return so keyboard focus never falls
    /// through to the document list behind it.
    private func handleSidebarKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125: return moveSidebar(by: 1)
        case 126: return moveSidebar(by: -1)
        case 124: return expandSidebarTarget()
        case 123: return collapseSidebarTarget()
        case 36, 76: return activateSidebarTarget()
        default: return false
        }
    }

    private func moveSidebar(by delta: Int) -> Bool {
        let targets = sidebarTargets
        guard !targets.isEmpty else { return true }
        let current = sidebarTarget ?? .shelf(shelves.current)
        let index = targets.firstIndex(of: current) ?? 0
        let next = index + delta
        guard targets.indices.contains(next) else { return true }
        let target = targets[next]
        sidebarTarget = target
        if case .shelf(let list) = target { shelves.current = list }
        if case .document(let key) = target { reviewing = key }
        return true
    }

    private func activateSidebarTarget() -> Bool {
        let target = sidebarTarget ?? .shelf(shelves.current)
        switch target {
        case .shelf(let list):
            chrome.setReading(false)
            openProject = nil
            shelves.current = list
        case .source(let path): explorerExpanded.insert(path)
        case .folder(let path): showFolder(path)
        case .document(let key): reviewing = key
        case .project(let id):
            chrome.setReading(false)
            openProject = projects.first { $0.id == id }
        case .tag(let name):
            chrome.setReading(false)
            openProject = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .showTagInCatalogue, object: nil,
                                                userInfo: ["tag": name])
            }
        case .addSource: importing = true
        }
        return true
    }

    /// Narrows the catalogue and the list to one folder and everything under it. The
    /// catalogue owns that state, so the intent is posted rather than reached for; this is
    /// what both a click on a folder row and Return on a focused one do.
    private func showFolder(_ path: String) {
        chrome.setReading(false)
        openProject = nil
        sidebarTarget = .folder(path)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openFolderInCatalogue, object: nil,
                                            userInfo: ["path": path])
        }
    }

    private func expandSidebarTarget() -> Bool {
        guard let target = sidebarTarget else { return true }
        switch target {
        case .source(let path), .folder(let path): explorerExpanded.insert(path)
        default: break
        }
        return true
    }

    private func collapseSidebarTarget() -> Bool {
        guard let target = sidebarTarget else { return true }
        switch target {
        case .source(let path), .folder(let path): explorerExpanded.remove(path)
        default: break
        }
        return true
    }

    // Not private: SidebarTests renders this on its own, squeezed, to check that it holds
    // its width rather than being compressed away.
    // MARK: Where you are

    /// Four rows at the top of the sidebar, because four questions get asked of a shelf
    /// often enough to deserve one each. Two of them cannot be typed into the search box
    /// at all: "carries no tag" is the absence of a term, and "opened but not finished"
    /// is a fact about the reader rather than about the file.
    private var shelvesPanel: some View {
        Section("Library") {
            ForEach(SmartList.allCases) { list in
                Button {
                    chrome.setReading(false)
                    openProject = nil
                    shelves.current = list
                    sidebarTarget = .shelf(list)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .showShelfInCatalogue, object: nil,
                            userInfo: ["shelf": list.rawValue])
                    }
                } label: {
                    sidebarRow(shelves.current == list) {
                        Label(list.title, systemImage: list.icon)
                    } trailing: {
                        Text(shelves.count(list, among: runner.results).formatted())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shelves.current == list ? .isSelected : [])
                .tip(list.explanation)
            }
        }
        .task(id: runner.revision) {
            await shelves.refresh()
            await libraryStatus.refresh()
        }
    }

    // MARK: Projects

    /// The projects, where a person looks for them. They were a sheet 720 points wide
    /// opened from a link buried in the library tab, which is a filing cabinet in a
    /// drawer.
    private var projectsPanel: some View {
        Section("Projects") {
            if Library.shared == nil {
                Text("The library is unavailable").foregroundStyle(.secondary)
            } else if projects.isEmpty {
                Text("No projects yet").foregroundStyle(.secondary)
            } else {
                ForEach(projects) { project in
                    // A row rather than a Button: a Button takes the drag for itself, so a
                    // paper dropped on a project landed on nothing and the project went on
                    // saying what it said before. The tap does what the Button did.
                    // A Button for the click, with the drop hung on the outside of it.
                    // Neither gesture on its own worked: a plain tap on a row of a sidebar
                    // `List` is swallowed by the list's own click handling, and so is a
                    // simultaneous one, so a project could not be opened by clicking it.
                    Button {
                        chrome.setReading(false)
                        openProject = openProject?.id == project.id ? nil : project
                        sidebarTarget = .project(project.id)
                    } label: {
                        sidebarRow(openProject?.id == project.id) {
                            Label(project.name, systemImage: "briefcase")
                        } trailing: {
                            Text(project.documentCount.formatted())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sidebarTarget == .project(project.id) ? .isSelected : [])
                    .background(dropProject == project.id
                                ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: Metric.control))
                    // `onDrop` rather than `dropDestination`: this is a row of a List, and
                    // the newer modifier does not receive drops there. Every drag in this
                    // app carries a file URL (the sidebar's own rows, the list's, the
                    // shelf's, and Finder's), so that is what it asks for.
                    .onDrop(of: [.fileURL], isTargeted: Binding(
                        get: { dropProject == project.id },
                        set: { targeted in
                            if targeted { dropProject = project.id }
                            else if dropProject == project.id { dropProject = nil }
                        }
                    )) { providers in
                        Task {
                            let urls = await droppedFileURLs(from: providers)
                            guard !urls.isEmpty else { return }
                            addFiles(urls, toProject: project.id)
                        }
                        return true
                    }
                    .tip("Ask a question across these \(project.documentCount) documents. "
                         + "Drop a PDF here to add it.")
                }
            }
            if namingProject {
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await createProject() } }
                    .onExitCommand { namingProject = false }
            } else {
                Button {
                    newProjectName = ""
                    namingProject = true
                } label: {
                    Label("New project", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
            }
        }
        .task(id: runner.revision) { await reloadProjects() }
    }

    /// The palette can name a project the sidebar would have to be scrolled to.
    private func revealProject(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? Int64 else { return }
        Task {
            await reloadProjects()
            openProject = projects.first { $0.id == id }
        }
    }

    /// A PDF dropped on a project row. The library is what knows which document a path is,
    /// so a path it has never seen is skipped rather than invented here.
    private func addFiles(_ urls: [URL], toProject id: Int64) {
        guard let library = Library.shared else { return }
        Task {
            let added = (try? await addToProject(urls.map(\.path), project: id, library: library)) ?? 0
            await reloadProjects()
            // The workspace, if it is the one open, is showing a list it read when it
            // opened. Dropping a paper on the project in the sidebar changes what the
            // project holds, so the list beside it has to be read again.
            if added > 0, openProject?.id == id { projectContentsRevision += 1 }
        }
    }

    /// Its own property: as one expression inside the window's body, the type-checker
    /// gives up on it.
    private var statusBar: some View {
        let reachable = selection.filter(isReachable).count
        return StatusBar(
            runner: runner,
            activity: runner.activity,
            watching: watchSources && reachable > 0,
            sources: reachable,
            unavailableSources: selection.count - reachable,
            spend: sessionSpendLabel,
            planIsCurrent: previewIsCurrent,
            selectedPath: selectedPath,
            lastOpened: selectionOpenedAt,
            bibliography: bibliographySummary,
            document: readerFacts,
            plan: planFacts
        )
    }

    /// The plan being worked through, when that is what the window is showing. Only the
    /// reviewer: the shelf is about a collection, and the bar under it should stay about
    /// the collection.
    private var planFacts: StatusBar.PlanFacts? {
        guard mode == .list, !runner.results.isEmpty, !chrome.reading else { return nil }
        return StatusBar.PlanFacts(
            total: runner.results.count,
            confirmed: runner.confirmedCount + runner.appliedCount,
            skipped: runner.skippedCount,
            trashed: runner.deletedCount,
            pending: runner.pendingCount,
            backupFolder: moveOriginals ? backup.safeFolderName : nil,
            sources: selection.filter(isReachable).count,
            builtAt: runner.builtAt
        )
    }

    /// The document the bar should describe, or nil when the window is showing a
    /// collection. Only while reading: the reviewer's bar is about the plan and the shelf
    /// it was built from, and a page is beside it rather than the subject of the window.
    private var readerFacts: StatusBar.DocumentFacts? {
        guard chrome.reading, let key = reviewing, let item = runner.item(key) else { return nil }
        return StatusBar.DocumentFacts(
            path: item.currentURL.path,
            bytes: item.byteCount,
            pages: annotator.pageCount > 0 ? annotator.pageCount : (item.pageCount ?? 0),
            locked: item.status == .locked,
            highlights: annotator.marks.count,
            notes: annotator.marks.filter { !$0.note.isEmpty }.count
        )
    }

    /// What the bibliography holds, for the bar, and only while the bibliography is what
    /// is on screen. Two keys that are the same is the one problem a .bib has that none of
    /// the entries can see on their own, so it is counted where the file is described.
    private var bibliographySummary: String? {
        guard mode == .bibliography, !runner.bib.isEmpty else { return nil }
        var parts = ["\(runner.bib.count) entries"]
        let short = runner.bib.filter { !$0.isComplete }.count
        if short > 0 { parts.append("\(short) incomplete") }
        let keys = runner.bib.map(\.key)
        let duplicates = keys.count - Set(keys).count
        parts.append("\(duplicates) duplicate key\(duplicates == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// Where the selected file is. One string rather than a chain inside the status bar's
    /// own arguments, which is more than the type-checker will work through in one pass.
    private var selectedPath: String? {
        guard let key = reviewing else { return nil }
        return runner.item(key)?.currentURL.path
    }

    /// When the selected document was last read. Nil for a file nobody has opened, which
    /// the bar says rather than leaving a blank where a date goes.
    private func readSelectionPosition() async {
        selectionOpenedAt = nil
        guard let key = reviewing, let library = Library.shared,
              let record = try? await library.document(atPath: key),
              let position = try? await library.readingPosition(forDocument: record.id)
        else { return }
        selectionOpenedAt = position.updatedAt
    }

    private func reloadProjects() async {
        guard let library = Library.shared else {
            projects = []
            return
        }
        let found = (try? await library.projects()) ?? []
        let counts = (try? await library.projectMemberCounts()) ?? [:]
        var summaries: [ProjectSummary] = []
        for project in found {
            summaries.append(ProjectSummary(id: project.id, name: project.name,
                                            documentCount: counts[project.id] ?? 0))
        }
        projects = summaries
    }

    private func createProject() async {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        namingProject = false
        guard !name.isEmpty, let library = Library.shared else { return }
        _ = try? await library.createProject(name: name)
        await reloadProjects()
    }

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
        .confirmationDialog("Delete Tag", isPresented: $deletingTag, presenting: tagBeingDeleted) { tag in
            Button("Delete", role: .destructive) { Task { await performDeleteTag(tag) } }
            Button("Cancel", role: .cancel) {}
        } message: { tag in
            Text("Deleting \"\(tag.name)\" removes it from \(tag.documents) document\(tag.documents == 1 ? "" : "s").")
        }
    }

    /// A stable colour for a tag, derived from its name.
    ///
    /// Tags carry no colour of their own and giving them one is a schema and a colour
    /// picker; this is the cheap half that gets the useful part. The same name always
    /// gets the same dot, on this machine and on any other, because the hash is written
    /// here rather than taken from `hashValue`, which is seeded per process.
    private func tagColour(_ name: String) -> Color {
        let palette: [Color] = [Ink.amber, Ink.blue, Ink.green, Ink.purple, Ink.red, Ink.magenta]
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func tagRow(_ tag: TagCount) -> some View {
        Button {
            chrome.setReading(false)
            openProject = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .showTagInCatalogue, object: nil, userInfo: ["tag": tag.name])
            }
            sidebarTarget = .tag(tag.name)
        } label: {
            sidebarRow(sidebarTarget == .tag(tag.name)) {
                HStack(spacing: 6) {
                    // A dot in the tag's own colour rather than a tag glyph on every row:
                    // a column of identical icons carries no information, and a colour
                    // makes a tag recognisable before its name is read.
                    Circle()
                        .fill(tagColour(tag.name))
                        .frame(width: 9, height: 9)
                        .padding(.horizontal, 2)
                    Text(tag.name)
                }
            } trailing: {
                Text(tag.documents.formatted())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sidebarTarget == .tag(tag.name) ? .isSelected : [])
        .tip("Show the \(tag.documents) document\(tag.documents == 1 ? "" : "s") carrying this tag")
        .contextMenu {
            Button("Rename…") {
                tagBeingRenamed = tag
                renamedTagText = tag.name
                renamingTag = true
            }
            Button("Delete", role: .destructive) {
                tagBeingDeleted = tag
                deletingTag = true
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

    /// Fold and unfold the whole tree, in the Sources header, beside what they fold.
    private var explorerFolding: some View {
        HStack(spacing: 2) {
            Button {
                explorerExpanded = explorerFolderIDs(explorerTree)
            } label: {
                Image(systemName: "chevron.down.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(runner.results.isEmpty)
            .tip("Unfold every folder")

            Button {
                explorerExpanded = []
            } label: {
                Image(systemName: "chevron.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(runner.results.isEmpty)
            .tip("Fold every folder")
        }
        .font(.caption)
    }

    /// Where the files come from, with what is inside them.
    ///
    /// The folder tree was a section of its own, which put "which folders are these files
    /// in" one level away from "where do the files come from" — the same question, one
    /// level down. Each source is the root of its own tree now, and unfolds into it.
    @ViewBuilder
    private var sourcesPanel: some View {
            Section {
                if selection.isEmpty {
                    Text("Nothing added yet")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }
                ForEach(selection, id: \.self) { url in
                    sourceRow(url)
                }
                // Adding a source is the `+` in the sidebar's footer now, where the count
                // of them is. A blue link in the middle of the column said the same thing
                // twice and moved down the window as sources were added.
            } header: {
                // Folding lives with the tree it folds. These buttons existed and were
                // never drawn, which on a source with several hundred folders is the
                // difference between a sidebar and a scroll.
                HStack(spacing: 4) {
                    Text("Sources")
                    Spacer(minLength: 4)
                    explorerFolding
                }
            }
            .task(id: runner.resultsToken) {
                explorerTree = buildExplorerTree(runner.results)
                // The roots open on their own: a tree that arrives entirely folded says
                // nothing about what was just scanned. Anything folded by hand below
                // them stays folded.
                explorerExpanded.formUnion(explorerTree.map(\.id))
            }
    }

    /// One source: its name, how many files it holds, and its folders underneath.
    @ViewBuilder
    private func sourceRow(_ url: URL) -> some View {
        let root = explorerTree.first { $0.url == url }
        let children = filterExplorerTree(root?.children ?? [], matching: sourceFilter)
        if let root, !children.isEmpty {
            DisclosureGroup(isExpanded: sourceExpansion(root.id)) {
                ExplorerOutline(nodes: children, expanded: $explorerExpanded,
                                selected: reviewing,
                                select: { reviewing = $0; sidebarTarget = .document($0) },
                                focusPath: { sidebarTarget = .folder($0) },
                                openFolder: showFolder,
                                focusedPath: focusedSidebarPath)
            } label: {
                sourceLabel(url, count: countOfFiles(in: root))
            }
        } else {
            sourceLabel(url, count: 0)
        }
    }

    private func sourceLabel(_ url: URL, count: Int) -> some View {
        let reachable = isReachable(url)
        return SidebarSourceLabel(
            url: url,
            count: count,
            reachable: reachable,
            focused: sidebarTarget == .source(url.path),
            hovered: hoveredSource == url,
            focus: { showFolder(url.path) },
            setHovered: { hoveredSource = $0 ? url : (hoveredSource == url ? nil : hoveredSource) },
            remove: { removeSource(url) }
        )
    }

    private func sourceExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { explorerExpanded.contains(id) },
            set: { open in
                if open { explorerExpanded.insert(id) } else { explorerExpanded.remove(id) }
            }
        )
    }

    private func countOfFiles(in node: ExplorerNode) -> Int {
        node.documentCount
    }

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

    /// The selection is a set of non-overlapping roots: a folder absorbs anything already
    /// picked inside it, and nothing already covered is added twice.
    private func add(_ urls: [URL]) {
        let before = selection
        selection = mergedSources(selection, adding: urls)
        guard selection.map(\.path) != before.map(\.path) else { return }
        persistSources()
        startWatching()
        if autoPreview { mode == .catalogue ? libraryPreview() : preview() }
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

    /// A missing external volume cannot receive an FSEvents stream. Check only the
    /// selected roots, not their contents, so plugging `brain` back in can resume the
    /// library without polling fourteen thousand files.
    private func watchSourceAvailability() async {
        while !Task.isCancelled {
            let current = Dictionary(uniqueKeysWithValues: selection.map { ($0.path, isReachable($0)) })
            let remounted = !sourceAvailability.isEmpty && current.contains { path, reachable in
                reachable && sourceAvailability[path] == false
            }
            sourceAvailability = current
            if remounted, watchSources {
                // Covers that failed against a disconnected volume are not failures of the
                // files; the ones on the drive that just came back deserve another try.
                covers.forget()
                startWatching()
                if autoPreview { mode == .catalogue ? libraryPreview() : preview() }
            }
            try? await Task.sleep(for: .seconds(3))
        }
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
        // Restored exactly as they were written. A source that cannot be reached right now
        // is not a source that has been removed: an external volume may not be mounted, and
        // a locally rebuilt app has a new signature, which is a new identity to the
        // system's privacy database — so ~/Desktop and ~/Documents read as missing until
        // access is granted again. Dropping them here, and writing the shortened list back,
        // deleted a person's configuration for a condition that clears on its own. The
        // sidebar says which ones it cannot see; nothing is forgotten without being asked.
        selection = storedSources
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// Whether a source can be read at all right now. Nil-safe and cheap enough for a
    /// sidebar row: `fileExists` is one stat call.
    func isReachable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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

private struct SidebarSourceLabel: View {
    let url: URL
    let count: Int
    let reachable: Bool
    let focused: Bool
    let hovered: Bool
    let focus: () -> Void
    let setHovered: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Only when something is wrong. A folder glyph on every source is a column of
            // identical icons beside a disclosure triangle that already says "folder";
            // the warning is the one state worth a symbol.
            if !reachable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Ink.amber)
            }
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(reachable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 6)
            if !reachable {
                Text("cannot be read")
                    .font(Face.caption)
                    .foregroundStyle(Ink.amber)
            } else if count > 0 {
                Text(count.formatted())
                    .font(Face.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if hovered {
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .tip("Stop watching this source. Nothing on disk is touched.")
            }
        }
        .contentShape(Rectangle())
        .background(focused ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .accessibilityAddTraits(focused ? .isSelected : [])
        .onTapGesture(perform: focus)
        .onHover(perform: setHovered)
        .help(reachable
              ? url.path
              : url.path + " — not reachable right now. The volume may be unmounted, or "
                + "this build may not have been granted access to the folder yet. It is "
                + "kept, and comes back on its own.")
    }
}

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
/// rather than the results tree's synthetic node ids (`buildTree(_:)` in PaperShelfCore
/// names a node after its path components, not the path itself), since offering to open a
/// folder in the catalogue needs a path that actually exists on disk.
struct ExplorerNode: Identifiable {
    let id: String
    let name: String
    let url: URL
    /// `Item.key`, or nil for a folder.
    let itemKey: String?
    let documentCount: Int
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
                return ExplorerNode(id: itemKey!, name: name, url: url, itemKey: itemKey,
                                   documentCount: 1, children: nil)
            }
            // Folders first, then alphabetical, the way Finder lists a folder.
            let sortedChildren = order.map { children[$0]! }.sorted { lhs, rhs in
                if (lhs.itemKey == nil) != (rhs.itemKey == nil) { return lhs.itemKey == nil }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            let builtChildren = sortedChildren.map { $0.node() }
            return ExplorerNode(id: url.path, name: name, url: url, itemKey: nil,
                                documentCount: builtChildren.reduce(0) { $0 + $1.documentCount },
                                children: builtChildren)
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

/// One row of the explorer as the sidebar draws it: the node and how deep it sits.
struct FlatExplorerRow: Identifiable {
    let node: ExplorerNode
    let depth: Int
    var id: String { node.id }
    var isFolder: Bool { node.children != nil }
}

/// The explorer tree as rows, in the order it reads, with folded folders left out.
///
/// Nested `DisclosureGroup`s build every row of every folder, open or not, and the whole
/// tree again on each pass -- and the sidebar's pass runs on every click in the list,
/// since the selected file is drawn here too. A flat array is what a `List` can be lazy
/// over, the same fix the results list already has (`flattenTree`).
func flattenExplorer(_ nodes: [ExplorerNode], expanded: Set<String>,
                     depth: Int = 0) -> [FlatExplorerRow] {
    var rows: [FlatExplorerRow] = []
    for node in nodes {
        rows.append(FlatExplorerRow(node: node, depth: depth))
        guard let children = node.children, expanded.contains(node.id) else { continue }
        rows.append(contentsOf: flattenExplorer(children, expanded: expanded, depth: depth + 1))
    }
    return rows
}

/// The Explorer's tree, folded and unfolded from the outside.
///
/// `OutlineGroup` keeps its own expansion state where nothing can reach it, which is fine
/// until a header offers "unfold everything". A shared set of open folder paths puts that
/// state somewhere both can act on, and the rows are flat so only what is on screen is
/// built.
struct ExplorerOutline: View {
    let nodes: [ExplorerNode]
    @Binding var expanded: Set<String>
    let selected: String?
    let select: (String) -> Void
    var focusPath: (String) -> Void = { _ in }
    /// Clicking a folder shows what is in it. The triangle beside it is what opens the
    /// folder to look inside; the row itself is the filter, which is what a folder in a
    /// sidebar means everywhere else.
    var openFolder: (String) -> Void = { _ in }
    var focusedPath: String? = nil

    var body: some View {
        ForEach(flattenExplorer(nodes, expanded: expanded)) { row in
            self.row(row.node, depth: row.depth)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Every row can be dragged onto a project. A folder means the documents in it, which
    /// is what a folder of papers is; the drop works that out (see `pdfsUnder`), so a
    /// chapter's worth of reading is one drag rather than forty.
    private func row(_ node: ExplorerNode, depth: Int) -> some View {
        rowLabel(node, depth: depth).draggable(node.url)
    }

    private func rowLabel(_ node: ExplorerNode, depth: Int) -> some View {
        HStack(spacing: 6) {
            // The triangle a `DisclosureGroup` used to draw. Flat rows have to draw their
            // own, and a file gets the same width of blank so the names line up.
            if node.children != nil {
                Button { toggle(node.id) } label: {
                    Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                        // Hit testing follows this shape rather than the glyph's own frame,
                        // so folding a folder doesn't need a 20pt-wide column -- the glyph
                        // and the rest of the row stay the size they were.
                        .contentShape(Rectangle().inset(by: -5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(expanded.contains(node.id) ? "Fold this folder" : "Unfold this folder")
            } else {
                Color.clear.frame(width: 10, height: 1)
            }
            Image(systemName: node.itemKey == nil ? "folder" : "doc")
                .foregroundStyle(node.itemKey == nil ? Color.accentColor : .secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(
            node.itemKey != nil && node.itemKey == selected
                ? Color.accentColor.opacity(0.15) : .clear
        )
        .background(node.url.path == focusedPath
                    ? Color.accentColor.opacity(0.12)
                    : .clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityAddTraits((node.itemKey == selected || node.url.path == focusedPath)
                                ? .isSelected : [])
        .onTapGesture {
            if let key = node.itemKey {
                select(key)
            } else {
                focusPath(node.url.path)
                openFolder(node.url.path)
            }
        }
        .contextMenu {
            if node.itemKey == nil {
                // A second way to fold a folder besides the 10pt-wide chevron, for a
                // right-click or a keyboard context-menu invocation.
                Button(expanded.contains(node.id) ? "Collapse" : "Expand") { toggle(node.id) }
                // The catalogue is the only thing that can honour the first of these, and
                // it owns its own state, so the intent is posted rather than reached for.
                Button("Show only this folder") { openFolder(node.url.path) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                Divider()
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
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
