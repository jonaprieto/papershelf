import SwiftUI
import AppKit
import PDFHammerCore

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
}

struct SettingsWindowView: View {
    @AppStorage("settingsPane") private var pane: SettingsPane = .general
    @StateObject private var palette = Palette()

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { Optional(pane) },
                set: { if let new = $0 { pane = new } }
            )) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(208)
        } detail: {
            Group {
                switch pane {
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
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("watchSources") private var watchSources = true
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("viewMode") private var mode: ViewMode = .catalogue

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Watch the sources for changes", isOn: $watchSources)
                Toggle("Plan as soon as a source is added", isOn: $autoPreview)
                Picker("Open in", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Running")
            } footer: {
                Text("The watcher checks each new file against what is already known rather "
                     + "than rescanning the shelf, which is what lets it notice a copy of "
                     + "something you already own as it arrives.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Highlighters

struct HighlighterSettings: View {
    @ObservedObject var palette: Palette

    var body: some View {
        Form {
            Section {
                ForEach(Array(palette.styles.enumerated()), id: \.element.id) { index, style in
                    HStack(spacing: 10) {
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
                                .font(.caption2.weight(.bold).monospaced())
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
                        .foregroundStyle(.tertiary)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(palette.styles) { style in
                    HStack(spacing: 10) {
                        Text(style.meaning.isEmpty ? "Highlight" : style.meaning)
                            .font(.system(.body, design: .serif))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
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
    @ObservedObject private var keymap = Keymap.shared
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
            HStack(spacing: 8) {
                TextField("Filter commands", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Spacer(minLength: 0)
                Button("Restore all") { keymap.resetAll() }
                    .disabled(!keymap.hasCustomisations)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

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
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onChange(of: recording) { startOrStopRecording() }
        .onDisappear { stopMonitoring() }
    }

    @ViewBuilder
    private func row(for command: Command) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(command.scope.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 74, alignment: .leading)

                Button {
                    recording = recording == command ? nil : command
                } label: {
                    if recording == command {
                        Text("Press the keys you want…")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if let shortcut = keymap.shortcut(for: command) {
                        Text(shortcut.display)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                    } else {
                        Text("unbound").font(.caption).foregroundStyle(.tertiary)
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
                .foregroundStyle(.tertiary)
                .opacity(keymap.isCustomised(command) ? 1 : 0)
                .help("Back to what it shipped with")
            }

            if let clash, clash.command == command {
                HStack(spacing: 8) {
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
                .font(.caption)
                .foregroundStyle(Ink.amber)
                .padding(8)
                .background(Ink.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: Metric.control))
            }
        }
        .padding(.vertical, 2)
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
    @AppStorage("bibType") private var type: BibType = .book
    @AppStorage("bibLineWidth") private var lineWidth = 80
    @AppStorage("bibIndent") private var indent = 2
    @AppStorage("bibAlign") private var align = true
    @AppStorage("bibDelimiter") private var delimiter: BibStyle.Delimiter = .braces
    @AppStorage("bibTrailingComma") private var trailingComma = true
    @AppStorage("bibBlankLines") private var blankLines = true
    @AppStorage("bibSortFields") private var sortFields = false
    @AppStorage("bibDropAllCaps") private var dropAllCaps = false
    @AppStorage("bibOmitFile") private var omitFile = true

    var body: some View {
        Form {
            Section {
                Picker("Entry type", selection: $type) {
                    ForEach(BibType.allCases) { Text("@\($0.rawValue)").tag($0) }
                }
                Toggle("Omit the file field", isOn: $omitFile)
            } header: {
                Text("Entries")
            } footer: {
                Text("The entry type decides what counts as missing. Publisher, journal and "
                     + "institution are never written and never reported as missing, because "
                     + "nothing here can read them off a PDF and a complaint you cannot act "
                     + "on is just noise.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Line width") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(lineWidth) },
                            set: { lineWidth = Int($0) }
                        ), in: 0...200, step: 10)
                        Text(lineWidth == 0 ? "off" : "\(lineWidth)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Picker("Indent", selection: $indent) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("None").tag(0)
                }
                Picker("Values in", selection: $delimiter) {
                    Text("{braces}").tag(BibStyle.Delimiter.braces)
                    Text("\"quotes\"").tag(BibStyle.Delimiter.quotes)
                }
                Toggle("Align the equals signs", isOn: $align)
                Toggle("Trailing comma", isOn: $trailingComma)
                Toggle("Blank line between entries", isOn: $blankLines)
                Toggle("Sort fields alphabetically", isOn: $sortFields)
                Toggle("Lowercase ALL-CAPS values", isOn: $dropAllCaps)
            } header: {
                Text("Formatting")
            } footer: {
                Text("A value longer than the line wraps onto indented continuations; a "
                     + "single word longer than the budget is left whole, since breaking a "
                     + "path to satisfy a column is worse than exceeding it.")
                .font(.caption).foregroundStyle(.secondary)
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
    private var server: URL? { ChatGPTPlugin.serverExecutableURL() }

    private var claudeCode: String {
        "claude mcp add pdf-hammer -- \"\(server?.path ?? "…")\""
    }

    private var codex: String {
        """
        [mcp_servers.pdf-hammer]
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
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Copy") { copy(server.path) }
                        }
                    }
                } else {
                    Label("No pdf-hammer-mcp next to this build. Install PDF Hammer.app first.",
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
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsPanel(sections: .plugin)

            Section {
                if let database = libraryDatabaseURL() {
                    LabeledContent("Database") {
                        HStack {
                            Text(database.path)
                                .font(.system(.caption, design: .monospaced))
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
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


// MARK: - Files and passwords

struct FileSettings: View {
    @AppStorage("passwords") private var passwordsText = ""
    @AppStorage("moveOriginals") private var moveOriginals = true
    @AppStorage("backupFolderName") private var backupFolderName = defaultBackupFolderName
    @AppStorage("backupCustomPath") private var backupCustomPath = ""
    @AppStorage("encryptOutput") private var encryptOutput = false
    @ObservedObject private var secret = SessionSecret.shared
    @State private var choosingBackupFolder = false
    @FocusState private var focused: Int?

    private var rows: [String] { PasswordList.rows(passwordsText) }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let rows = PasswordList.rows(passwordsText)
                return rows.indices.contains(index) ? rows[index] : ""
            },
            set: { passwordsText = PasswordList.setting(index, to: $0, in: passwordsText) }
        )
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, _ in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        SecureField("", text: binding(index), prompt: Text("Password"))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: index)
                        Button {
                            passwordsText = PasswordList.removing(index, from: passwordsText)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
                Button {
                    let added = PasswordList.addingRow(to: passwordsText)
                    passwordsText = added.text
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
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep the originals", isOn: $moveOriginals)
                if moveOriginals {
                    if backupCustomPath.isEmpty {
                        LabeledContent("Folder") {
                            TextField("", text: $backupFolderName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        Button("Use one folder for everything…") { choosingBackupFolder = true }
                            .buttonStyle(.link)
                    } else {
                        LabeledContent("Folder") {
                            HStack {
                                Text(backupCustomPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Change…") { choosingBackupFolder = true }
                                Button("Use a folder per source") { backupCustomPath = "" }
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
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Lock the output with a password", isOn: $encryptOutput)
                if encryptOutput {
                    LabeledContent("Password") {
                        SecureField("", text: $secret.encryptPassword, prompt: Text("required"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    if secret.encryptPassword.isEmpty {
                        Text("Nothing will be written until this has a value.")
                            .font(.caption)
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
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingBackupFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { backupCustomPath = url.path }
        }
    }
}
