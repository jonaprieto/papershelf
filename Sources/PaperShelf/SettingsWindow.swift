import SwiftUI
import AppKit
import PaperShelfCore

/// Settings, in a window of their own.
///
/// They were twelve buttons in a rail beside the library, which put "which folder am I
/// looking at" and "what is my API key" at the same level and gave the sidebar two jobs.
/// These are the things you set once and rarely return to; the sidebar is where you are.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, files, naming, bibtex, highlighters, keyboard, ai, integrations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .files: return "Files & passwords"
        case .naming: return "Name rules"
        case .bibtex: return "BibTeX"
        case .highlighters: return "Highlighters"
        case .keyboard: return "Keyboard"
        case .ai: return "AI & spend"
        case .integrations: return "Integrations"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .files: return "folder"
        case .naming: return "textformat"
        case .bibtex: return "text.quote"
        case .highlighters: return "highlighter"
        case .keyboard: return "keyboard"
        case .ai: return "sparkles"
        case .integrations: return "puzzlepiece.extension"
        }
    }

    /// What someone might type looking for this pane, in their own words rather than the
    /// app's. "Password" is in two panes and belongs in both; "dark mode" is not a phrase
    /// this app uses anywhere and is exactly what a person will search for.
    var keywords: [String] {
        switch self {
        case .general:
            return ["appearance", "theme", "dark mode", "light", "night", "tint", "sources",
                    "folders", "watch", "scan", "open in", "view"]
        case .files:
            return ["password", "encrypted", "locked", "originals", "backup", "trash",
                    "cache", "covers"]
        case .naming:
            return ["pattern", "rename", "case", "separator", "accents", "date", "year",
                    "length", "tokens", "chips"]
        case .bibtex:
            return ["citation", "biblatex", "entry", "braces", "wrap", "fields", "cite"]
        case .highlighters:
            return ["colour", "color", "highlight", "marks", "meaning", "annotations"]
        case .keyboard:
            return ["shortcut", "keys", "bindings", "conflict", "rebind"]
        case .ai:
            return ["api key", "openai", "model", "endpoint", "price", "spend", "cost",
                    "tokens"]
        case .integrations:
            return ["mcp", "claude", "codex", "chatgpt", "plugin", "markdown", "convert",
                    "database", "sqlite"]
        }
    }

    func matches(_ needle: String) -> Bool {
        let text = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        return title.lowercased().contains(text) || keywords.contains { $0.contains(text) }
    }
}

struct SettingsWindowView: View {
    private let prefs = Prefs.shared
    private let palette: Palette = .shared
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search settings", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, Space.step)
                    .padding(.vertical, Space.step)
                paneList
            }
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    /// Panes matching what was typed. Never empty: a search that matches nothing leaves
    /// the whole list rather than an empty window with no way back.
    private var shown: [SettingsPane] {
        let matching = SettingsPane.allCases.filter { $0.matches(search) }
        return matching.isEmpty ? SettingsPane.allCases : matching
    }

    private var paneList: some View {
            List(shown, selection: Binding(
                get: { Optional(prefs.settingsPane) },
                set: { if let new = $0 { prefs.settingsPane = new } }
            )) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(208)
    }

    private var detail: some View {
            Group {
                switch prefs.settingsPane {
                case .general: GeneralSettings()
                case .files: FileSettings()
                case .naming: NameRulesSettings()
                case .bibtex: BibtexSettings()
                case .highlighters: HighlighterSettings(palette: palette)
                case .keyboard: KeyboardSettings()
                case .ai: Form { SettingsPanel(sections: .ai) }.formStyle(.grouped)
                case .integrations: IntegrationSettings()
                }
            }
            .frame(minWidth: 560, minHeight: 420)
            .navigationTitle(prefs.settingsPane.title)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable private var prefs = Prefs.shared
    @State private var addingSource = false

    private var sources: [URL] {
        prefs.sources.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $prefs.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Tint the page while reading in the dark", isOn: $prefs.readingTint)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Tinting rather than inverting, so figures and scanned plates stay "
                     + "readable. Highlights drop to 30% so they tint the paper instead of "
                     + "glowing off it.")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if sources.isEmpty {
                    Text("Nothing added yet").foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent, systemImage: "folder")
                        Spacer()
                        Text(url.deletingLastPathComponent().path)
                            .font(Face.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button {
                            remove(url)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button {
                    addingSource = true
                } label: {
                    Label("Add a folder or a PDF", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
            } header: {
                Text("Sources")
            } footer: {
                Text("Kept as a set of non-overlapping roots. Picking a folder absorbs "
                     + "anything already selected inside it — a file reachable from two "
                     + "roots would be attributed to whichever was scanned first, and that "
                     + "root decides where its originals land.")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .fileImporter(isPresented: $addingSource,
                          allowedContentTypes: [.pdf, .folder],
                          allowsMultipleSelection: true) { outcome in
                guard case .success(let urls) = outcome else { return }
                add(urls)
            }

            Section {
                LabeledContent("Documents no source accounts for") {
                    HStack(spacing: Space.step) {
                        if let vanished {
                            Text("\(vanished)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Button(checking ? "Checking\u{2026}" : "Check") { Task { await check() } }
                            .disabled(checking)
                        if let vanished, vanished > 0 {
                            Button("Forget them\u{2026}", role: .destructive) { confirmingTidy = true }
                        }
                    }
                }
            } header: {
                Text("Tidy the library")
            } footer: {
                Text("A document belongs here because a source brought it. This finds the "
                     + "ones no source accounts for any more \u{2014} a folder that stopped "
                     + "being a source, or a file deleted out of one that did not \u{2014} "
                     + "and forgets them, along with their tags, notes, place in any "
                     + "reading project and reading position.\n\n"
                     + "A file missing from a folder that is missing too is left alone: an "
                     + "unplugged drive is not a deleted library. Nothing on disk is "
                     + "touched either way.")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .confirmationDialog("Forget \(vanished ?? 0) document\((vanished ?? 0) == 1 ? "" : "s")?",
                                isPresented: $confirmingTidy, titleVisibility: .visible) {
                Button("Forget them", role: .destructive) { Task { await tidy() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their tags, notes, place in any reading project and reading position "
                     + "go with them. Nothing on disk is touched.")
            }

            Section {
                Toggle("Watch the sources for changes", isOn: $prefs.watchSources)
                Toggle("Plan as soon as a source is added", isOn: $prefs.autoPreview)
                Toggle("Return in the name field renames the file", isOn: $prefs.returnAppliesRename)
                Picker("Open in", selection: $prefs.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Running")
            } footer: {
                Text("Return renames the file there and then. Turn it off to have Return "
                     + "confirm the name into the plan instead, to be carried out with "
                     + "everything else when you apply.\n\n"
                     + "The watcher checks each new file against what is already known rather "
                     + "than rescanning the shelf, which is what lets it notice a copy of "
                     + "something you already own as it arrives.")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// How many documents the library holds that no source accounts for, once asked.
    /// Nil before anybody asks: a number that appears on its own reads as a problem
    /// rather than as an answer to a question.
    @State private var vanished: Int?
    @State private var checking = false
    @State private var confirmingTidy = false
    @State private var doomed: [String] = []

    private func check() async {
        guard let library = Library.shared else { return }
        checking = true
        defer { checking = false }
        let known = (try? await library.locationsByDocument()) ?? [:]
        let manager = FileManager.default
        let roots = sources.map { $0.resolvingSymlinksInPath().path }
        doomed = strayDocuments(known, sources: roots) { manager.fileExists(atPath: $0) }
        vanished = doomed.count
    }

    private func tidy() async {
        guard let library = Library.shared, !doomed.isEmpty else { return }
        _ = try? await library.forget(documents: doomed)
        doomed = []
        vanished = 0
        await LibraryStatus.shared.refresh()
        await Shelves.shared.refresh()
    }

    /// The same merge the sidebar does, through the same preference: a source added here
    /// and a source added there have to end up as one non-overlapping set, or the two
    /// lists disagree about what is being scanned.
    private func add(_ urls: [URL]) {
        let merged = mergedSources(sources, adding: urls)
        prefs.sources = merged.map(\.path).joined(separator: "\n")
    }

    /// Removing a source here forgets what it brought, exactly as removing one from the
    /// sidebar does. This edited the preference and nothing else, which is one of the two
    /// ways a library ended up holding papers from folders nobody watches.
    private func remove(_ url: URL) {
        forget(url)
        removeFromList(url)
    }

    private func forget(_ url: URL) {
        guard let library = Library.shared else { return }
        Task {
            let root = url.resolvingSymlinksInPath().path
            let doomed = (try? await library.documentsOnly(under: root)) ?? []
            _ = try? await library.forget(documents: doomed)
            await LibraryStatus.shared.refresh()
            await Shelves.shared.refresh()
        }
    }

    private func removeFromList(_ url: URL) {
        prefs.sources = sources.filter { $0 != url }.map(\.path).joined(separator: "\n")
    }
}

// MARK: - Highlighters

struct HighlighterSettings: View {
    var palette: Palette
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                ForEach(Array(palette.styles.enumerated()), id: \.element.id) { index, style in
                    HStack(spacing: Space.step) {
                        ColorPicker("", selection: Binding(
                            get: { style.swatch },
                            set: { palette.setColour($0, on: style) }
                        ))
                        .labelsHidden()

                        TextField("", text: Binding(
                            get: { style.meaning },
                            set: { palette.setMeaning($0, on: style) }
                        ), prompt: Text("What it means"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)

                        // The number key that paints in this colour, which follows the row
                        // rather than the colour: reorder them and the keys reorder too.
                        if index < 9 {
                            Text("\(index + 1)")
                                .font(Face.mono.weight(.bold))
                                .frame(width: 16, height: 16)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: Metric.keyCap))
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            palette.remove(style)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(palette.styles.count < 2)
                        .help(palette.styles.count < 2
                              ? "The last colour stays; without one there is no highlighter"
                              : "Remove this colour")
                    }
                }

                HStack {
                    Button { palette.add() } label: {
                        Label("Add a colour", systemImage: "plus.circle")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Reset to the five defaults") { palette.resetToDefaults() }
                        .buttonStyle(.link)
                }
            } header: {
                Text("Your highlighters")
            } footer: {
                Text("Shown beside the bar as you highlight and next to every mark, so the "
                     + "convention is legible where it is used rather than remembered. The "
                     + "number keys follow this order.")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Label them with the nearest colour I use", isOn: $prefs.labelForeignMarks)
            } header: {
                Text("Marks made in other apps")
            } footer: {
                Text("A book highlighted in Preview or Skim keeps its colours; this only "
                     + "decides what those colours are called in your notes. Anything "
                     + "further away than a close match stays plain “Highlight”, and "
                     + "nothing is ever repainted.")
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(palette.styles) { style in
                    HStack(spacing: Space.step) {
                        Text(style.meaning.isEmpty ? "Highlight" : style.meaning)
                            .font(Face.page)
                            .padding(.horizontal, Space.snug)
                            .padding(.vertical, Space.hair)
                            .background(style.swatch.opacity(0.38),
                                        in: RoundedRectangle(cornerRadius: 3))
                        Spacer(minLength: 0)
                    }
                }
            } header: {
                Text("In the page")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

/// Every command, what it answers to, and where. The list the `?` sheet used to show was
/// typed out by hand beside the monitor that actually implemented it; this one is the
/// monitor's own table, so it cannot drift, and a binding can be changed.
struct KeyboardSettings: View {
    private let keymap = Keymap.shared
    @State private var filter = ""
    @State private var recording: Command?
    @State private var clash: Clash?
    @State private var monitor: Any?

    /// A key a person asked for that something else already answers to. Held rather than
    /// applied, because taking a key from another command silently is how a shortcut
    /// quietly stops working.
    struct Clash: Equatable {
        let command: Command
        let shortcut: Shortcut
        let taken: Command
    }

    private var groups: [(Command.Group, [Command])] {
        Command.Group.allCases.compactMap { group in
            let matching = Command.allCases.filter { command in
                guard command.group == group else { return false }
                guard !filter.isEmpty else { return true }
                let needle = filter.lowercased()
                return command.title.lowercased().contains(needle)
                    || (keymap.shortcut(for: command)?.display.lowercased().contains(needle) ?? false)
                    || command.scope.label.lowercased().contains(needle)
            }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.step) {
                TextField("Filter commands", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Spacer(minLength: 0)
                Button("Restore all") { keymap.resetAll() }
                    .disabled(!keymap.hasCustomisations)
                Button("Export…") { exportTable() }
                    .help("Copies every command, where it works and what it answers to, "
                          + "as Markdown")
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.step)

            Divider()

            List {
                ForEach(groups, id: \.0) { group, commands in
                    Section(group.label) {
                        ForEach(commands) { command in
                            row(for: command)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            Text("Letters work whenever a text field is not focused; anything with ⌘ works "
                 + "regardless. A command with no shortcut is still reachable — every row "
                 + "here is also a line in the command palette.")
            .font(Face.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.step)
        }
        .onChange(of: recording) { startOrStopRecording() }
        .onDisappear { stopMonitoring() }
    }

    /// The whole table as Markdown, on the clipboard. A keyboard layout somebody has
    /// tuned is worth being able to print, paste into notes, or hand to someone else.
    private func exportTable() {
        var lines = ["| Command | Where it works | Shortcut |", "| --- | --- | --- |"]
        for (group, commands) in groups {
            lines.append("| **\(group.label)** | | |")
            for command in commands {
                let key = keymap.shortcut(for: command)?.display ?? "—"
                lines.append("| \(command.title) | \(command.scope.label) | \(key) |")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @ViewBuilder
    private func row(for command: Command) -> some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.roomy) {
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: Space.step)
                Text(command.scope.label)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)

                Button {
                    recording = recording == command ? nil : command
                } label: {
                    if recording == command {
                        Text("Press the keys you want…")
                            .font(Face.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if let shortcut = keymap.shortcut(for: command) {
                        Text(shortcut.display)
                            .font(Face.mono.weight(.semibold))
                    } else {
                        Text("unbound").font(Face.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 168, alignment: .trailing)

                Button {
                    keymap.reset(command)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(keymap.isCustomised(command) ? 1 : 0)
                .help("Back to what it shipped with")
            }

            if let clash, clash.command == command {
                HStack(spacing: Space.step) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(clash.shortcut.display) already means “\(clash.taken.title)”. "
                         + "Two commands cannot share a key in the same place.")
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Take it anyway") {
                        keymap.bind(clash.taken, to: nil)
                        keymap.bind(clash.command, to: clash.shortcut)
                        self.clash = nil
                    }
                    Button("Cancel") { self.clash = nil }
                }
                .font(Face.caption)
                .foregroundStyle(Ink.amber)
                .padding(Space.step)
                .background(Ink.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: Metric.control))
            }
        }
        .padding(.vertical, Space.hair)
    }

    // MARK: Recording

    private func startOrStopRecording() {
        stopMonitoring()
        guard let command = recording else { return }
        clash = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape leaves the binding alone, which is the only way out that does not
            // require choosing a key you did not want.
            if event.keyCode == 53 {
                recording = nil
                return nil
            }
            guard let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return nil }
            let shortcut = Shortcut(typed, Shortcut.Modifiers(
                event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
            if let taken = keymap.conflict(for: shortcut, assigning: command) {
                clash = Clash(command: command, shortcut: shortcut, taken: taken)
            } else {
                keymap.bind(command, to: shortcut)
            }
            recording = nil
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}


// MARK: - BibTeX

struct BibtexSettings: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Picker("Entry type", selection: $prefs.bibType) {
                    ForEach(BibType.allCases) { Text("@\($0.rawValue)").tag($0) }
                }
                Toggle("Omit the file field", isOn: $prefs.bibOmitFile)
            } header: {
                Text("Entries")
            } footer: {
                Text("The entry type decides what counts as missing. Publisher, journal and "
                     + "institution are never written and never reported as missing, because "
                     + "nothing here can read them off a PDF and a complaint you cannot act "
                     + "on is just noise.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Line width") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(prefs.bibLineWidth) },
                            set: { prefs.bibLineWidth = Int($0) }
                        ), in: 0...200, step: 10)
                        Text(prefs.bibLineWidth == 0 ? "off" : "\(prefs.bibLineWidth)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Picker("Indent", selection: $prefs.bibIndent) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("None").tag(0)
                }
                Picker("Values in", selection: $prefs.bibDelimiter) {
                    Text("{braces}").tag(BibStyle.Delimiter.braces)
                    Text("\"quotes\"").tag(BibStyle.Delimiter.quotes)
                }
                Toggle("Align the equals signs", isOn: $prefs.bibAlign)
                Toggle("Trailing comma", isOn: $prefs.bibTrailingComma)
                Toggle("Blank line between entries", isOn: $prefs.bibBlankLines)
                Toggle("Sort fields alphabetically", isOn: $prefs.bibSortFields)
                Toggle("Lowercase ALL-CAPS values", isOn: $prefs.bibDropAllCaps)
            } header: {
                Text("Formatting")
            } footer: {
                Text("A value longer than the line wraps onto indented continuations; a "
                     + "single word longer than the budget is left whole, since breaking a "
                     + "path to satisfy a column is worse than exceeding it.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

/// Where the MCP server finally has a face. It has shipped inside the app for a while and
/// the only way to find out how to point an editor at it was the README.
struct IntegrationSettings: View {
    @Bindable private var prefs = Prefs.shared
    @State private var installed: Set<String> = []

    private var server: URL? { ChatGPTPlugin.serverExecutableURL() }

    private var claudeCode: String {
        "claude mcp add papershelf -- \"\(server?.path ?? "…")\""
    }

    private var codex: String {
        """
        [mcp_servers.papershelf]
        command = "\(server?.path ?? "…")"
        """
    }

    var body: some View {
        Form {
            Section {
                if let server {
                    LabeledContent("Server") {
                        HStack {
                            Text(server.path)
                                .font(Face.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Copy") { copy(server.path) }
                        }
                    }
                } else {
                    Label("No papershelf-mcp next to this build. Install PaperShelf first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Claude Code") {
                    Button("Copy the command") { copy(claudeCode) }
                }
                LabeledContent("Codex") {
                    Button("Copy the config") { copy(codex) }
                }
            } header: {
                Text("Model Context Protocol")
            } footer: {
                Text("list_documents, search_documents, read_document, bibliography and "
                     + "find_duplicates. A separate binary that holds no state, so every "
                     + "call names the folder it works on, and nothing leaves the machine.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsPanel(sections: .plugin)

            Section {
                Picker("Converter", selection: $prefs.defaultConverter) {
                    Text("Automatic (best for the document)").tag("")
                    Text("Built-in reader").tag(builtInReaderName)
                    Text("Built-in OCR").tag(builtInOCRName)
                    ForEach(markdownConverters, id: \.name) { converter in
                        Text(installed.contains(converter.name)
                             ? converter.name
                             : "\(converter.name) — not installed")
                            .tag(converter.name)
                    }
                }
            } header: {
                Text("Converting to Markdown")
            } footer: {
                Text("Two of these need nothing installed. The reader takes the "
                     + "document's own text layer, which is exact and instant; the OCR "
                     + "reads the pages as pictures with the recognition built into "
                     + "macOS, which is the only one here that can read a scan. The rest "
                     + "are found on your PATH and keep more of the layout. Automatic "
                     + "picks per document: an installed converter, then the text layer, "
                     + "then OCR for a document that has none. This is what the "
                     + "conversion sheet starts on, and what a reading project reads its "
                     + "own documents with.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Offer “Open in ChatGPT” beside a highlight", isOn: $prefs.offerChatGPT)
                    .disabled(!ChatGPTHandoff.isInstalled)
                Toggle("Also offer “Copy for ChatGPT”", isOn: $prefs.offerChatGPTCopy)
                    .disabled(!ChatGPTHandoff.isInstalled)
                if !ChatGPTHandoff.isInstalled {
                    Text("ChatGPT is not installed, so neither is offered.")
                        .font(Face.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Hand-off while reading")
            } footer: {
                Text("Neither sends anything on its own: the passage lands in the composer "
                     + "and you decide. The app can address a new thread but not one you "
                     + "already have open, which is why copying is offered as well.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if let database = libraryDatabaseURL() {
                    LabeledContent("Database") {
                        HStack {
                            Text(database.path)
                                .font(Face.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([database])
                            }
                        }
                    }
                } else {
                    Text("The database could not be located.").foregroundStyle(.secondary)
                }
            } header: {
                Text("The library")
            } footer: {
                Text("SQLite rather than a JSON file because two processes use it: the app "
                     + "writes while the MCP server reads.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            // Which tools are actually on this machine. `locate` looks at the places a
            // GUI app's inherited PATH does not have, which is why a converter installed
            // by Homebrew was invisible before.
            installed = Set(markdownConverters.filter { locate($0.executable) != nil }.map(\.name))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


// MARK: - Files and passwords

struct FileSettings: View {
    @Bindable private var prefs = Prefs.shared
    @Bindable private var secret = SessionSecret.shared
    @State private var choosingBackupFolder = false
    @FocusState private var focused: Int?

    private var rows: [String] { PasswordList.rows(prefs.passwords) }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let rows = PasswordList.rows(prefs.passwords)
                return rows.indices.contains(index) ? rows[index] : ""
            },
            set: { prefs.passwords = PasswordList.setting(index, to: $0, in: prefs.passwords) }
        )
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, _ in
                    HStack(spacing: Space.step) {
                        Text("\(index + 1)")
                            .font(Face.micro.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        SecureField("", text: binding(index), prompt: Text("Password"))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: index)
                        Button {
                            prefs.passwords = PasswordList.removing(index, from: prefs.passwords)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button {
                    let added = PasswordList.addingRow(to: prefs.passwords)
                    prefs.passwords = added.text
                    DispatchQueue.main.async { focused = added.focus }
                } label: {
                    Label("Add password", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
            } header: {
                Text("Passwords to try")
            } footer: {
                Text("Tried in order; the first that opens a file wins. A file that no "
                     + "password opened is passed through untouched and marked Locked "
                     + "rather than skipped silently.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep the originals", isOn: $prefs.moveOriginals)
                if prefs.moveOriginals {
                    if prefs.backupCustomPath.isEmpty {
                        LabeledContent("Folder") {
                            TextField("", text: $prefs.backupFolderName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        Button("Use one folder for everything…") { choosingBackupFolder = true }
                            .buttonStyle(.link)
                    } else {
                        LabeledContent("Folder") {
                            HStack {
                                Text(prefs.backupCustomPath)
                                    .font(Face.mono)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Change…") { choosingBackupFolder = true }
                                Button("Use a folder per source") { prefs.backupCustomPath = "" }
                            }
                        }
                    }
                }
            } header: {
                Text("Originals")
            } footer: {
                Text("Point everything at one folder and each source still gets its own "
                     + "subfolder there, so two roots holding the same relative path cannot "
                     + "collide. Delete always means the Trash, never an outright removal.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Lock the output with a password", isOn: $prefs.encryptOutput)
                if prefs.encryptOutput {
                    LabeledContent("Password") {
                        SecureField("", text: $secret.encryptPassword, prompt: Text("required"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    if secret.encryptPassword.isEmpty {
                        Text("Nothing will be written until this has a value.")
                            .font(Face.caption)
                            .foregroundStyle(Ink.amber)
                    }
                }
            } header: {
                Text("Locking the output")
            } footer: {
                Text("The inverse of the rest of the app, and held in memory only, so it has "
                     + "to be given again each launch. A file that no password opened is "
                     + "passed through as it is rather than being sealed with a new one, "
                     + "since that would strand it behind a password it never had.")
                .font(Face.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingBackupFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { prefs.backupCustomPath = url.path }
        }
    }
}
