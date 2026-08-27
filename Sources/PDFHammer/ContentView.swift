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
    /// Kept in memory only. A password written into a preferences plist is not a password.
    @State private var encryptPassword = ""
    @AppStorage("backupFolderName") private var backupFolderName = defaultBackupFolderName
    @AppStorage("backupCustomPath") private var backupCustomPath = ""
    /// Deliberately not @AppStorage: a password does not belong in a preferences plist.
    @State private var choosingBackupFolder = false
    @State private var savingLog = false
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
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://api.openai.com/v1"
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
    @AppStorage("sidebarTab") private var sidebarTab: SidebarTab = .sources
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    @StateObject private var runner = Runner()
    @StateObject private var covers = Covers()
    @State private var selection: [URL] = []
    @State private var importing = false
    /// Folders start closed. Only what has been opened, or opened for you to reach the
    /// selected file, is in here.
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

    private var aiClient: AIClient {
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

    private var namePattern: NamePattern {
        NamePattern(parsing: namePatternText, maxTotalLength: namePatternMaxLength)
    }

    /// Every chip and text-field edit goes through here, so the two stay in sync: both
    /// read and write the same pair of AppStorage values.
    private func updateNamePattern(_ transform: (inout NamePattern) -> Void) {
        var updated = namePattern
        transform(&updated)
        namePatternText = updated.text
        namePatternMaxLength = updated.maxTotalLength
    }

    private func updateNameToken(at index: Int, _ transform: (inout NameToken) -> Void) {
        updateNamePattern { pattern in
            guard pattern.elements.indices.contains(index),
                  case .token(var token) = pattern.elements[index] else { return }
            transform(&token)
            pattern.elements[index] = .token(token)
        }
    }

    /// Runs once: a user who already had toggles set gets an arranged pattern that
    /// reproduces them, rather than landing on today's plain default and looking like
    /// their settings were dropped. After this the pattern is its own preference and the
    /// toggles it replaces (date position, date format, max length) are read here only.
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

    /// The document a chip's own preview value is drawn from: whichever file is open for
    /// review, else the first result, so the row means something before anything is
    /// selected.
    private var namePatternReferenceItem: Item? {
        reviewing.flatMap(runner.item) ?? runner.results.first
    }

    private var namePatternReferencePreview: NamePreview? {
        guard let item = namePatternReferenceItem else { return nil }
        // Qualified: this type's own `preview()` (the toolbar action) would otherwise
        // shadow PDFHammerCore's free function of the same name.
        return PDFHammerCore.preview(namePattern, for: item, guess: runner.guesses[item.key], under: item.root)
    }

    /// Matched by position among token elements, not by kind: two tokens of the same
    /// kind can carry different options and must not be shown each other's value.
    private func namePatternChipPreview(atElementIndex index: Int) -> NameTokenPreview? {
        let tokenIndex = namePattern.elements[..<index].reduce(into: 0) { count, element in
            if case .token = element { count += 1 }
        }
        let tokens = namePatternReferencePreview?.tokens ?? []
        return tokens.indices.contains(tokenIndex) ? tokens[tokenIndex] : nil
    }

    private func namingLabel(for kind: NameToken.Kind) -> String {
        switch kind {
        case .date: return "Date"
        case .year: return "Year"
        case .title: return "Title"
        case .author: return "Author"
        case .publisher: return "Publisher"
        case .journal: return "Journal"
        case .folder: return "Folder"
        case .originalStem: return "Original name"
        case .counter: return "Counter"
        }
    }

    private func namingLabel(for casing: NameToken.Casing) -> String {
        switch casing {
        case .unchanged: return "As is"
        case .lower: return "lowercase"
        case .upper: return "UPPERCASE"
        case .titleCase: return "Title Case"
        }
    }

    private func namingLabel(for abbreviation: NameToken.Abbreviation) -> String {
        switch abbreviation {
        case .none: return "Full"
        case .compact: return "Compact"
        case .surname: return "Surname only"
        case .initials: return "Initials"
        }
    }

    /// Casing is a no-op on a token that is already digits.
    private func showsCasing(_ kind: NameToken.Kind) -> Bool {
        switch kind {
        case .date, .year, .counter: return false
        default: return true
        }
    }

    /// Exercises every rule at once, so the footer shows what each switch actually does.
    private static let sampleName = "Extracto Señor_Acme 66 (1)_23_08_2026.pdf"

    private func options(dryRun: Bool) -> Options {
        // Subfolders are always included; the preview shows exactly what that reaches.
        Options(passwords: passwords, recursive: true, dryRun: dryRun,
                backup: backup,
                encryption: EncryptionSettings(enabled: encryptOutput, password: encryptPassword),
                useFolderNames: useFolderNames,
                useMetadataDate: useMetadataDate, useFileDate: useFileDate, rules: rules)
    }

    /// What only a fresh scan can answer: which files there are, and which of them open.
    /// Change one of these and the preview no longer describes reality, so Apply is
    /// blocked until Preview runs again.
    private var fingerprint: String {
        [
            selection.map(\.path).joined(separator: "|"),
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

    /// Applying needs a preview that still matches the settings, every file reviewed, and
    /// at least one of them kept.
    private var canApply: Bool {
        previewIsCurrent && runner.allReviewed && runner.actionable > 0 && !runner.busy
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $chrome.columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 310, max: 400)
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
                .frame(minWidth: SplitLayout.minWidth(
                    notesShown: chrome.notesShown, contentsShown: chrome.contentsShown))
                .navigationTitle("PDF Hammer")
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        // The sidebar's own floor (matching the min above) plus the detail pane's.
        .frame(minWidth: 290 + SplitLayout.minWidth(
            notesShown: chrome.notesShown, contentsShown: chrome.contentsShown), minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .onChange(of: runner.canUndo) { _, can in chrome.canUndo = can }
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
        .fileExporter(isPresented: $savingLog,
                      document: TextDocument(text: logText(runner.log)),
                      contentType: .plainText,
                      defaultFilename: "pdf-hammer-log.txt") { _ in }
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

    private var subtitle: String {
        switch runner.phase {
        case .scanning: return "Scanning, \(runner.found) PDF\(runner.found == 1 ? "" : "s") found"
        case .processing: return "Processing \(runner.done) of \(runner.total)"
        case .idle: break
        }
        guard !runner.results.isEmpty else {
            return selection.isEmpty ? "No sources" : "\(selection.count) source\(selection.count == 1 ? "" : "s")"
        }
        if !runner.lastRunWasDry { return "Applied to \(runner.results.count) files" }
        guard previewIsCurrent else { return "Preview is out of date" }
        return runner.pendingCount == 0
            ? "All \(runner.results.count) reviewed, ready to apply"
            : "\(runner.reviewed) of \(runner.results.count) reviewed"
    }

    // MARK: Sidebar

    /// An icon rail with one panel behind it, the way an editor does it. Everything used
    /// to be one long scroll of nine sections; this shows one job at a time.
    private var sidebar: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            Form {
                switch sidebarTab {
                case .sources: sourcesPanel
                case .passwords: passwordsPanel
                case .naming:
                    namingPanel
                    datesPanel
                case .files:
                    originalsPanel
                    runningPanel
                case .ai: aiPanel
                case .bibtex: bibtexPanel
                case .reading: readingPanel
                case .log: logPanel
                case .appearance: appearancePanel
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                RailButton(tab: tab, isSelected: sidebarTab == tab) { sidebarTab = tab }
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tip("API key, model and endpoint", key: "⌘,")
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .background(.quaternary.opacity(0.25))
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
    private var passwordsPanel: some View {
            Section {
                ForEach(Array(passwordRows.enumerated()), id: \.offset) { index, _ in
                    HStack(spacing: 6) {
                        // Without labelsHidden the Form treats the string as a left-hand
                        // label and squeezes the field into the value column.
                        TextField("", text: passwordBinding(index), prompt: Text("Password"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .focused($focusedPassword, equals: index)
                            .onSubmit(addPassword)
                        Button {
                            passwordsText = PasswordList.removing(index, from: passwordsText)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .tip("Remove this password")
                        .help("Remove this password")
                        .accessibilityLabel("Remove password \(index + 1)")
                    }
                }
                Button(action: addPassword) {
                    Label("Add password", systemImage: "plus.circle")
                }
                .tip("Another password to try, in order")
                .buttonStyle(.link)
            } header: {
                Text("Passwords")
            } footer: {
                if passwords.isEmpty {
                    Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                         text: "No passwords set. Encrypted files will be renamed but stay locked.",
                         size: .caption)
                } else {
                    Text("Tried in order, top to bottom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }


    @ViewBuilder
    private var namingPanel: some View {
            Section {
                HStack(spacing: 6) {
                    ForEach(NamePattern.presets) { preset in
                        Button(preset.name) {
                            updateNamePattern { $0 = preset.pattern }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(preset.summary)
                    }
                }
                .padding(.vertical, 2)

                namingChipRow
                    .tip("Drag a field to reorder it, click one to adjust it")

                LabeledContent("Pattern") {
                    TextField("", text: $namePatternText, prompt: Text("[date]-[title]"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
                .tip("Chips and this text describe the same pattern; edit whichever is easier")
            } header: {
                Text("Naming pattern")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Note(icon: "info.circle.fill", tint: .secondary,
                         text: "Preview only for now: Preview and Apply still use Name rules below.",
                         size: .caption)
                    namingPreviewFooter
                }
            }

            Section {
                Picker("Case", selection: $ruleCasing) {
                    ForEach(NameRules.Casing.allCases) { Text($0.label).tag($0) }
                }
                .help("Applied to the whole name, date aside")
                Picker("Separators", selection: $ruleSeparator) {
                    ForEach(NameRules.Separator.allCases) { Text($0.label).tag($0) }
                }
                .tip("How runs of spaces, dashes and underscores are written")
                Toggle("Remove symbols", isOn: $ruleStripSymbols)
                    .tip("Punctuation becomes a separator: report (1)! reads report-1")
                Toggle("Remove accents", isOn: $ruleStripDiacritics)
                    .help("señor becomes senor. Separate from Remove symbols, since ñ is a letter")
                Toggle("ASCII only", isOn: $ruleAsciiOnly)
                    .tip("Non-ASCII becomes a separator, so words stay apart")
                Toggle("Drop a leading The, A, El…", isOn: $ruleDropArticles)
                    .help("So a shelf sorts by what the book is called rather than by its article")
                Picker("Date goes", selection: $ruleDatePosition) {
                    ForEach(NameRules.DatePosition.allCases) { Text($0.label).tag($0) }
                }
                .help("Whether the date leads the name or trails it")
                Picker("Date looks like", selection: $ruleDateFormat) {
                    ForEach(NameRules.DateFormat.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Max length") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { Double(ruleMaxLength) },
                                              set: { ruleMaxLength = Int($0) }),
                               in: 0...120, step: 5)
                        Text(ruleMaxLength == 0 ? "off" : "\(ruleMaxLength)")
                            .monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                    }
                }
                .tip("Trims the name on a word boundary; the date is never cut")
            } header: {
                // These three, plus everything above, are what Preview and Apply actually
                // use (NameRules/normalizedName, Hammer.swift): the Naming pattern section
                // above is not wired into that pipeline yet (render()'s own header comment
                // in Patterns.swift says as much), so these controls stay here rather than
                // being retired in favour of a pattern that does not yet drive real output.
                Text("Name rules")
            } footer: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.sampleName)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.tertiary)
                        Text(normalizedName(for: Self.sampleName, rules: rules))
                    }
                }
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
            }
    }

    private var namingChipRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(namePattern.elements.enumerated()), id: \.offset) { index, element in
                chipView(for: element, at: index)
                    .onDrag {
                        draggingElementIndex = index
                        return NSItemProvider(object: String(index) as NSString)
                    }
                    .onDrop(of: [.text], delegate: ChipDropDelegate(
                        index: index,
                        draggingIndex: $draggingElementIndex,
                        reorder: { from, to in
                            updateNamePattern { pattern in
                                guard pattern.elements.indices.contains(from),
                                      pattern.elements.indices.contains(to) else { return }
                                let moved = pattern.elements.remove(at: from)
                                pattern.elements.insert(moved, at: to)
                            }
                        }
                    ))
            }
            addTokenMenu
        }
    }

    @ViewBuilder
    private func chipView(for element: NameElement, at index: Int) -> some View {
        switch element {
        case .token(let token):
            tokenChip(token, at: index)
        case .literal(let text):
            literalChip(text, at: index)
        }
    }

    private func tokenChip(_ token: NameToken, at index: Int) -> some View {
        let preview = namePatternChipPreview(atElementIndex: index)
        return HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(namingLabel(for: token.kind))
                    .font(.caption2.weight(.semibold))
                if let preview, !preview.isEmpty {
                    Text(preview.value)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 90, alignment: .leading)
                } else {
                    Text("empty")
                        .font(.caption2.italic())
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                updateNamePattern { $0.elements.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Remove \(namingLabel(for: token.kind))")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.tertiary.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture { editingElementIndex = index }
        .popover(isPresented: Binding(
            get: { editingElementIndex == index },
            set: { if !$0 { editingElementIndex = nil } }
        )) {
            tokenOptions(token, at: index)
        }
    }

    private func literalChip(_ text: String, at index: Int) -> some View {
        HStack(spacing: 3) {
            Text(text.isEmpty ? "·" : text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                updateNamePattern { $0.elements.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Remove separator")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tokenOptions(_ token: NameToken, at index: Int) -> some View {
        let maxLengthLabel = token.maxLength == 0 ? "Max length: off" : "Max length: \(token.maxLength)"
        Form {
            if showsCasing(token.kind) {
                Picker("Case", selection: Binding(
                    get: { token.casing },
                    set: { newValue in updateNameToken(at: index) { $0.casing = newValue } }
                )) {
                    ForEach(NameToken.Casing.allCases) { Text(namingLabel(for: $0)).tag($0) }
                }
            }
            Picker("Shorten", selection: Binding(
                get: { token.abbreviation },
                set: { newValue in updateNameToken(at: index) { $0.abbreviation = newValue } }
            )) {
                ForEach(NameToken.Abbreviation.allCases) { Text(namingLabel(for: $0)).tag($0) }
            }
            Stepper(maxLengthLabel, value: Binding(
                get: { token.maxLength },
                set: { newValue in updateNameToken(at: index) { $0.maxLength = newValue } }
            ), in: 0...80, step: 5)
        }
        .padding(14)
        .frame(width: 230)
    }

    private var addTokenMenu: some View {
        Menu {
            ForEach(NameToken.Kind.allCases) { kind in
                Button(namingLabel(for: kind)) {
                    updateNamePattern { pattern in
                        // A token landing directly against another token with nothing
                        // between them renders glued together (assemble() in
                        // Patterns.swift only drops a separator, never adds one), so a
                        // dash goes in first when the pattern does not already end on
                        // one of its own.
                        if case .token = pattern.elements.last {
                            pattern.elements.append(.literal("-"))
                        }
                        pattern.elements.append(.token(NameToken(kind)))
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tip("Add a field to the pattern")
    }

    @ViewBuilder
    private var namingPreviewFooter: some View {
        let samples = Array(runner.results.prefix(5))
        VStack(alignment: .leading, spacing: 3) {
            if samples.isEmpty {
                Text("Preview appears once files are found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(samples) { item in
                    let rendered = PDFHammerCore.preview(namePattern, for: item, guess: runner.guesses[item.key], under: item.root)
                    HStack(spacing: 4) {
                        Text(rendered.originalName)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(rendered.renderedName)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
        }
        .font(.caption.monospaced())
        .padding(.top, 2)
    }


    @ViewBuilder
    private var datesPanel: some View {
            Section {
                Toggle("Use the folder name", isOn: $useFolderNames)
                    .tip("Take the date, and a name for scan001, from the folder")
                Toggle("Use the PDF's creation date", isOn: $useMetadataDate)
                    .tip("When the PDF was written, often long after the period it covers")
                Toggle("Use the file's modification date", isOn: $useFileDate)
                    .tip("Least trustworthy: often just when the file landed here")
            } header: {
                Text("When the filename has no date")
            } footer: {
                Text("Tried in this order. A date already in the filename always wins, "
                     + "since it is the only one the document itself states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }


    @ViewBuilder
    private var originalsPanel: some View {
        if !moveOriginals {
            Section {
                Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                     text: "Applying will replace the originals. Nothing is kept and there is no undo.")
            }
        }

            Section {
                Toggle("Lock the output with a password", isOn: $encryptOutput)
                    .tip("Write every file out locked with your password")
                if encryptOutput {
                    LabeledContent("Password") {
                        SecureField("", text: $encryptPassword, prompt: Text("required"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Text("Encryption")
            } footer: {
                Text(encryptOutput && encryptPassword.isEmpty
                     ? "Without a password nothing is encrypted."
                     : "Held in memory only, never written to preferences, so it has to be "
                       + "given again next launch. A file no password opened is passed "
                       + "through as it is rather than being sealed with one it never had.")
                    .font(.caption)
                    .foregroundStyle(encryptOutput && encryptPassword.isEmpty
                                     ? Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
                                     : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep the originals", isOn: $moveOriginals)
                    .help("Off replaces each file in place, with no copy kept and no undo")
                if moveOriginals {
                    if backupCustomPath.isEmpty {
                        LabeledContent("Folder") {
                            TextField("", text: $backupFolderName, prompt: Text(defaultBackupFolderName))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                        }
                    } else {
                        LabeledContent("Folder") {
                            Text(backupCustomPath)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    HStack {
                        Button("Choose folder…") { choosingBackupFolder = true }
                            .buttonStyle(.link)
                            .tip("One folder for the originals of every source")
                        Spacer()
                        if !backupCustomPath.isEmpty {
                            Button("Use a folder per source") { backupCustomPath = "" }
                                .buttonStyle(.link)
                        }
                    }
                }
            } header: {
                Text("Originals")
            } footer: {
                Text(backupSummary)
                    .font(.caption)
                    .foregroundStyle(moveOriginals ? .secondary : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }


    @ViewBuilder
    private var aiPanel: some View {
            Section {
                LabeledContent("API key") {
                    if aiReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    } else {
                        Label("Not set", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    }
                }
                if availableModels.isEmpty {
                    LabeledContent("Model") {
                        TextField("", text: $aiModel, prompt: Text("gpt-4o-mini"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                } else {
                    Picker("Model", selection: $aiModel) {
                        // The stored one may not be in the list; keep it selectable.
                        if !availableModels.contains(aiModel) {
                            Text(aiModel).tag(aiModel)
                        }
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button(loadingModels ? "Loading…" : "Refresh models", action: loadModels)
                        .buttonStyle(.link)
                        .tip("Ask the endpoint what it can run")
                        .disabled(!aiReady || loadingModels)
                    if let modelsError {
                        Text(modelsError)
                            .font(.caption)
                            .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                            .lineLimit(2)
                    }
                }
                Toggle("Ask on each new file", isOn: $autoIdentify)
                    .disabled(!aiReady)
                    .help("One request per file as you reach it, billed like any other")
                SettingsLink {
                    Label("Open settings", systemImage: "gearshape")
                }
                .buttonStyle(.link)
                if aiReady && runner.pendingCount > 0 && runner.lastRunWasDry {
                    Button {
                        Task { await runner.identifyPending(client: aiClient, passwords: passwords, rules: rules) }
                    } label: {
                        Label("Name the \(runner.pendingCount) still pending", systemImage: "sparkles")
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("AI")
            } footer: {
                Text("Suggestions still go through the name rules above, and still have to "
                     + "be confirmed. Only the filename and the opening text are sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }


    @ViewBuilder
    private var runningPanel: some View {
            Section("Running") {
                Toggle("Watch the sources for changes", isOn: $watchSources)
                    .tip("Pick up new files on their own, keeping this review")
                    .onChange(of: watchSources) { _, _ in startWatching() }
                Picker("Default view", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Preview as soon as a source is added", isOn: $autoPreview)
                    .help("Preview is read-only, so this changes nothing on disk")
            }
    }


    @ViewBuilder
    private var bibtexPanel: some View {
            Section {
                Picker("Entry type", selection: $bibType) {
                    ForEach(BibType.allCases) { Text($0.label).tag($0) }
                }
                .help("Decides which fields count as missing. @misc asks only for a title.")
            } header: {
                Text("Entries")
            } footer: {
                Text("Publisher, journal and institution are never written: nothing here "
                     + "can read them off a PDF, so they are not reported as missing either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Line width") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { Double(bibLineWidth) },
                                              set: { bibLineWidth = Int($0) }),
                               in: 0...200, step: 10)
                        Text(bibLineWidth == 0 ? "off" : "\(bibLineWidth)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Picker("Indent", selection: $bibIndent) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("None").tag(0)
                }
                Picker("Values in", selection: $bibDelimiter) {
                    ForEach(BibStyle.Delimiter.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Align the equals signs", isOn: $bibAlign)
                Toggle("Trailing comma", isOn: $bibTrailingComma)
                Toggle("Blank line between entries", isOn: $bibBlankLines)
                Toggle("Sort fields alphabetically", isOn: $bibSortFields)
                Toggle("Lowercase ALL-CAPS values", isOn: $bibDropAllCaps)
                Toggle("Omit the file field", isOn: $bibOmitFile)
            } header: {
                Text("BibTeX")
            } footer: {
                Text("A long value wraps onto indented continuations. A single word "
                     + "longer than the budget is left whole, since breaking a path to "
                     + "satisfy a column is worse than exceeding it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }


    @ViewBuilder
    private var readingPanel: some View {
        Section {
            ForEach(palette.styles) { style in
                HStack(spacing: 8) {
                    ColorPicker("", selection: Binding(
                        get: { style.swatch },
                        set: { palette.setColour($0, on: style) }
                    ))
                    .labelsHidden()
                    .tip("Pick this highlighter's colour")

                    TextField("", text: Binding(
                        get: { style.meaning },
                        set: { palette.setMeaning($0, on: style) }
                    ), prompt: Text("What it means"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)

                    Button {
                        palette.remove(style)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(palette.styles.count < 2)
                    .tip(palette.styles.count < 2
                         ? "The last colour stays; without one there is no highlighter"
                         : "Remove this colour")
                }
            }

            HStack {
                Button { palette.add() } label: {
                    Label("Add a colour", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                .tip("Another highlighter, with its own meaning")
                Spacer()
                Button("Reset") { palette.resetToDefaults() }
                    .buttonStyle(.link)
                    .tip("Back to the five it started with")
            }
        } header: {
            Text("Highlighters")
        } footer: {
            Text("Shown beside the bar as you highlight and next to every mark, so the "
                 + "convention is legible where it is used rather than remembered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Mode") {
            Toggle("Reading mode", isOn: $chrome.reading)
                .tip("Hide the list, the header and the deciding controls", key: "⌘⇧R")
        }
    }

    @ViewBuilder
    private var logPanel: some View {
        Section {
            if runner.log.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            } else {
                // Newest first: the last thing that happened is what you came to check.
                ForEach(runner.log.reversed().prefix(200)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.kind.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(logColour(entry.kind))
                            Text(entry.at, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(entry.subject)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        } header: {
            Text("Activity")
        } footer: {
            HStack {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText(runner.log), forType: .string)
                }
                .buttonStyle(.link)
                .disabled(runner.log.isEmpty)
                Spacer()
                Button("Save…") { savingLog = true }
                    .buttonStyle(.link)
                    .disabled(runner.log.isEmpty)
            }
        }
    }

    private func logColour(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .failed: return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
        case .trashed: return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
        case .moved: return Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
        case .decrypted, .renamed, .applied: return Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
        case .skipped: return .secondary
        default: return Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
        }
    }

    @ViewBuilder
    private var appearancePanel: some View {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
    }


    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("API key, model and endpoint")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { chrome.reading.toggle() }
            } label: {
                Label("Reading", systemImage: chrome.reading ? "book.fill" : "book")
            }
            .tip("Hide everything but the page", key: "⌘⇧R")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            switch runner.phase {
            case .scanning:
                ProgressView().controlSize(.small)
            case .processing:
                ProgressView(value: Double(runner.done), total: Double(max(runner.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            case .idle:
                EmptyView()
            }

            Button(action: preview) {
                Label("Preview", systemImage: "eye")
            }
            .labelStyle(.titleAndIcon)
            .tip("Read-only: builds the plan, touches nothing", key: "⌘P")
            .disabled(selection.isEmpty || runner.busy)
            .keyboardShortcut("p", modifiers: .command)
            .help("Read-only. Builds the plan without touching a file.")

            Button(action: confirmApply) {
                Label(canApply ? "Apply to \(runner.actionable) files" : "Apply",
                      systemImage: "checkmark.circle")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
            .tip("Carry out the reviewed plan on disk", key: "⌘Return")
            .keyboardShortcut(.return, modifiers: .command)
            .help("Carry out the reviewed plan on disk")
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

enum SidebarTab: String, CaseIterable, Identifiable {
    case sources, passwords, naming, files, ai, bibtex, reading, log, appearance

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sources: return "folder"
        case .passwords: return "key"
        case .naming: return "textformat"
        case .files: return "tray.full"
        case .ai: return "sparkles"
        case .bibtex: return "text.quote"
        case .reading: return "highlighter"
        case .log: return "list.bullet.rectangle"
        case .appearance: return "paintbrush"
        }
    }

    var title: String {
        switch self {
        case .sources: return "Sources"
        case .passwords: return "Passwords"
        case .naming: return "Name rules"
        case .files: return "Files"
        case .ai: return "AI"
        case .bibtex: return "BibTeX"
        case .reading: return "Reading"
        case .log: return "Activity"
        case .appearance: return "Appearance"
        }
    }
}

struct RailButton: View {
    let tab: SidebarTab
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            Image(systemName: tab.icon)
                .font(.system(size: 15))
                .frame(width: 34, height: 32)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.15)
                              : hovering ? Color.secondary.opacity(0.12) : .clear)
                )
                // The marker an editor puts on the active tab.
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? Color.accentColor : .clear)
                        .frame(width: 2, height: 18)
                        .offset(x: -6)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(tab.title)
        .accessibilityLabel(tab.title)
    }
}

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
            ("⌘P", "preview"),
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
