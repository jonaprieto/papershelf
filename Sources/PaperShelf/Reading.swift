import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PaperShelfCore

/// One highlight or note, in the rail beside the page.
struct MarkRow: View {
    let mark: Annotator.Mark
    let isSelected: Bool
    let jump: () -> Void
    let remove: () -> Void
    let save: (String) -> Void
    let recolour: (NSColor) -> Void
    let styles: [HighlightStyle]
    let meaning: String
    let styleMeaning: (HighlightStyle) -> String
    /// Named in the handoff so an answer is about the right document.
    var documentTitle: String = ""

    @State private var editing = false
    @State private var hovering = false
    /// Hovered, selected, or being written on: any of the three means the row is the one
    /// being worked on.
    private var showsActions: Bool { hovering || editing || isSelected }
    @State private var text = ""
    private let prefs = Prefs.shared

    /// The colour it was actually painted with, whatever palette that came from.
    private var colour: Color { Color(nsColor: mark.colour) }

    private var handoffPrompt: String {
        ChatGPTHandoff.prompt(quoted: mark.quoted, note: mark.note, page: mark.page,
                              title: documentTitle)
    }

    var body: some View {
        // Three lines, in the order a person reads them: what this mark means, what the
        // page says, and what you thought about it. The old row led with the quotation
        // and put the meaning underneath in small grey type, which made a column of marks
        // read as a column of unattributed quotations.
        VStack(alignment: .leading, spacing: Space.step) {
            HStack(spacing: Space.step) {
                Menu {
                    ForEach(styles) { style in
                        Button { recolour(style.nsColor) } label: {
                            // See the toolbar's picker: a symbol in a menu item is
                            // repainted, so every choice came out the same colour.
                            Label {
                                Text(styleMeaning(style))
                            } icon: {
                                swatchImage(style.nsColor, size: 12)
                            }
                        }
                    }
                } label: {
                    // A drawn swatch: see `swatchImage`. A shape here is not drawn and a
                    // symbol here is repainted, so a column of marks came out colourless.
                    swatchImage(mark.colour, size: 13)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tip("What this colour means. Pick another to repaint the mark.")

                Text(meaning)
                    .font(Face.headline)
                    .lineLimit(1)

                Spacer(minLength: Space.snug)

                Text("p. \(mark.page)")
                    .font(Face.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !mark.quoted.isEmpty {
                // Set as the page sets it, in quotation marks, on its own highlight. A
                // passage lifted out of a document should still look like the document.
                Text("\u{201C}\(mark.quoted)\u{201D}")
                    .font(Face.page)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.step)
                    .padding(.vertical, Space.step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colour.opacity(0.42), in: RoundedRectangle(cornerRadius: Metric.card))
            }

            if !mark.note.isEmpty && !editing {
                Text(mark.note)
                    .font(Face.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if editing {
                TextField("Note", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                HStack {
                    Button("Save") {
                        save(text)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Cancel") { editing = false }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Edge to edge rather than a rounded card inset from the panel: the marks are a
        // list, and a selected row in a list is a band, not a floating tile.
        .background(isSelected ? Color.accentColor.opacity(0.09) : .clear)
        // Floated over the row rather than laid out in it. In the row they were three
        // controls' worth of width that a mark's meaning had to fit around, so "Definition
        // or key term" was drawn as "Definition or key…" on every mark, all the time, to
        // make room for buttons nobody could see.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Space.hair) { rowActions }
                .padding(.horizontal, Space.snug)
                .padding(.vertical, Space.tight)
                .background(.regularMaterial, in: Capsule())
                .padding(.trailing, Space.step)
                .padding(.top, Space.tight)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: jump)
    }

    /// Edit, delete and the handoff. Always in the tree so keyboard focus and VoiceOver
    /// can reach them; only their opacity is gated. Three icons on every mark turned a
    /// column of quotations into a column of buttons, and none of them needs to be seen
    /// until you are looking at the mark they belong to.
    ///
    /// Shown while the row is selected as well as while it is hovered. Clicking a mark
    /// selects it and jumps the page to it, which is exactly the moment somebody wants to
    /// recolour it or write on it, and until now that took moving the pointer back to a
    /// row they had already chosen.
    @ViewBuilder
    private var rowActions: some View {
        if ChatGPTHandoff.isInstalled, prefs.offerChatGPT || prefs.offerChatGPTCopy,
           !mark.quoted.isEmpty || !mark.note.isEmpty {
            Menu {
                if prefs.offerChatGPT {
                    Button("Open in ChatGPT") { ChatGPTHandoff.open(handoffPrompt) }
                }
                if prefs.offerChatGPTCopy {
                    Button("Copy for ChatGPT") { ChatGPTHandoff.copy(handoffPrompt) }
                }
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(showsActions ? 1 : 0)
            .accessibilityLabel("Send the mark on page \(mark.page) to ChatGPT")
            .tip("Send this passage to ChatGPT. Open starts a new conversation; "
                 + "copy is for one you already have going.")
        }
        Button {
            text = mark.note
            editing.toggle()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(showsActions ? 1 : 0)
        .tip(mark.note.isEmpty ? "Add a note here" : "Edit this note")
        .accessibilityLabel(mark.note.isEmpty
                             ? "Add a note to the mark on page \(mark.page)"
                             : "Edit the note on the mark on page \(mark.page)")
        Button(action: remove) { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(showsActions ? 1 : 0)
            .tip("Remove this mark from the file")
            .accessibilityLabel("Delete the mark on page \(mark.page)")
    }
}

/// The marks beside the page. A window-level pane like the sidebar, not part of the
/// inspector: nesting it inside a column that is already width-constrained made the two
/// of them overflow the frame and draw over the browser.
struct NotesRail: View {
    var annotator: Annotator
    var palette: Palette
    @Binding var addingNote: Bool
    @Binding var noteText: String
    let lastColour: NSColor
    let title: String
    let source: String
    let close: () -> Void
    /// Opening this document at a page, for a mark on a document the reader does not have
    /// open. Nil where there is nothing to open onto.
    var openAtPage: ((Int) -> Void)?
    /// Its own bar, with the count, the export menu and the way out. Off when it sits in
    /// the inspector, which already has one of those and does not need two.
    var showsHeader: Bool = true
    /// Projects are optional because the standalone reader is not attached to the shelf.
    var projectScopes: [HighlightMeaningScope] = []
    /// The library identity keeps a paper override attached when its filename changes.
    var documentID: String? = nil
    /// Only memberships of this paper participate in automatic project precedence. The
    /// separate `projectScopes` list remains available for the explicit scope picker.
    var effectiveProjectScopes: [HighlightMeaningScope] = []

    /// Whether the document this panel is about is the one the reader has open.
    ///
    /// Marks are read off the live `PDFView`, and the annotator holds whichever document
    /// was opened last. The panel never checked that it was the same one, so selecting a
    /// paper on the shelf left the previous paper's highlights listed underneath it --
    /// nine passages about linearisability shown as though they had been marked on a
    /// document that has never been opened. Wrong is worse than empty.
    private var documentIsOpen: Bool {
        guard let open = annotator.url, !source.isEmpty else { return false }
        return open.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: source).resolvingSymlinksInPath().path
    }

    /// The marks to show, from whichever annotator holds this document.
    private var marks: [Annotator.Mark] { live.marks }

    /// The document that is selected but not open, read into an annotator of its own.
    ///
    /// Not a second kind of mark with a second kind of row. Highlights live in the PDF, so
    /// the panel needs the file loaded either way; loading it into an `Annotator` bound to
    /// a `PDFView` nothing shows means the rows, the colour menu, the note editor, the
    /// delete and the handoff are the same component here as they are beside the page.
    @State private var shadow = Annotator()
    @State private var shadowView = PDFView()
    @State private var readingFile = false

    /// Whichever annotator holds the document the panel is about: the reader's when it has
    /// this document open, the shadow one when the shelf merely has it selected.
    private var live: Annotator { documentIsOpen ? annotator : shadow }

    /// What is on this document, counted the two ways a reader counts it: passages picked
    /// out, and passages written about.
    private var tally: String {
        if !documentIsOpen && readingFile { return "Reading the file" }
        let highlights = marks.count
        guard highlights > 0 else {
            return documentIsOpen ? "No marks yet" : "No marks in this document"
        }
        let counted = count(highlights, marks.filter { !$0.note.isEmpty }.count)
        return documentIsOpen ? counted : counted + " · read from the file"
    }

    private func count(_ highlights: Int, _ notes: Int) -> String {
        "\(highlights) highlight\(highlights == 1 ? "" : "s") · "
            + "\(notes) note\(notes == 1 ? "" : "s")"
    }

    /// Loads the selected document into the shadow annotator, so its marks are the same
    /// marks the reader would show, in the same rows, with the same things you can do to
    /// them.
    ///
    /// The file is parsed off the main thread, which is where a two hundred page thesis
    /// costs a tenth of a second, and handed to a `PDFView` that is never added to a
    /// window: `Annotator` works through a view, and a view with no superview is a cheaper
    /// thing to give it than a second implementation of everything it does.
    private func loadSelectedDocument() async {
        guard !documentIsOpen, !source.isEmpty else { return }
        let url = URL(fileURLWithPath: source)
        guard shadow.url?.resolvingSymlinksInPath() != url.resolvingSymlinksInPath() else { return }
        readingFile = true
        defer { readingFile = false }
        let passwords = PasswordList.active(Prefs.shared.passwords)
        let document = await Task.detached { () -> PDFDocument? in
            guard let document = PDFDocument(url: url) else { return nil }
            if document.isLocked {
                for password in passwords where document.unlock(withPassword: password) { break }
                guard !document.isLocked else { return nil }
            }
            return document
        }.value
        guard !Task.isCancelled, let document else { return }
        shadowView.document = document
        shadow.attach(shadowView, url: url)
    }

    /// The meanings actually on this document, so the filter offers what is there rather
    /// than the whole palette.
    private var meaningsPresent: [String] {
        var seen: [String] = []
        for mark in marks {
            let meaning = palette.meaning(for: mark.colour, scopes: effectiveMeaningScopes)
            if !seen.contains(meaning) { seen.append(meaning) }
        }
        return seen
    }

    private var shownMarks: [Annotator.Mark] {
        guard let filter else { return marks }
        return marks.filter {
            palette.meaning(for: $0.colour, scopes: effectiveMeaningScopes) == filter
        }
    }

    private var defaultMeaningScope: HighlightMeaningScope? {
        guard !source.isEmpty else { return nil }
        return .forDocument(URL(fileURLWithPath: source), id: documentID)
    }

    private var currentMeaningScope: HighlightMeaningScope? {
        activeMeaningScope ?? defaultMeaningScope
    }

    private var effectiveMeaningScopes: [HighlightMeaningScope] {
        if let activeMeaningScope { return [activeMeaningScope] }
        return ([defaultMeaningScope].compactMap { $0 } + effectiveProjectScopes + [.library])
    }

    private var availableMeaningScopes: [HighlightMeaningScope] {
        var scopes: [HighlightMeaningScope] = []
        if let defaultMeaningScope { scopes.append(defaultMeaningScope) }
        scopes.append(contentsOf: projectScopes)
        scopes.append(.library)
        return scopes
    }

    var body: some View {
        panel
            .task(id: source) { await loadSelectedDocument() }
            .task(id: documentIsOpen) { await loadSelectedDocument() }
            // Whatever the shadow document still owes the disk it owes now, rather than
            // whenever the panel happens to be torn down.
            .onDisappear { shadow.flush() }
            .onChange(of: source) { _, _ in activeMeaningScope = nil }
            .sheet(item: $editingMeaningScope) { scope in
                HighlightMeaningEditor(palette: palette, scope: scope)
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack {
                    Text("Notes").font(Face.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .tip("Hide the notes", key: "⌘⇧N")
                }
                .padding(.horizontal, Space.roomy)
                .padding(.vertical, Space.step)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }

            summaryBar
            Divider()

            // A `List`, not a `ScrollView` of a `LazyVStack`: a scroll proxy cannot reach
            // a lazy row that has not been built yet, so asking it to follow the page did
            // nothing for every mark below the fold -- which is all the ones worth
            // scrolling to.
            ScrollViewReader { notes in
                List {
                    if addingNote {
                        VStack(alignment: .leading, spacing: Space.snug) {
                            Text("Note on the selection")
                                .font(Face.caption).foregroundStyle(.secondary)
                            TextField("What is worth remembering", text: $noteText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...5)
                                .focused($noteInputFocused)
                            HStack {
                                Button("Save") {
                                    if annotator.hasSelection {
                                        annotator.highlightSelection(colour: lastColour, note: noteText)
                                    } else if let id = annotator.selectedMark,
                                              let mark = marks.first(where: { $0.id == id }) {
                                        annotator.setNote(noteText, on: mark)
                                    }
                                    noteText = ""
                                    addingNote = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { noteText = ""; addingNote = false }
                            }
                        }
                        .padding(Space.roomy)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if marks.isEmpty && !addingNote {
                        Text(documentIsOpen
                             ? "Select text on the page to highlight it or attach a note."
                             : (readingFile ? "Reading the file."
                                : "Nothing is marked in this document yet."))
                            .font(Face.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Space.roomy)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(shownMarks) { mark in
                        MarkRow(
                            mark: mark,
                            isSelected: live.selectedMark == mark.id,
                            jump: {
                                if documentIsOpen { annotator.jump(to: mark) }
                                else { openAtPage?(mark.page) }
                            },
                            remove: { live.remove(mark) },
                            save: { live.setNote($0, on: mark) },
                            recolour: { live.setColour($0, on: mark) },
                            styles: palette.styles,
                            meaning: palette.meaning(for: mark.colour, scopes: effectiveMeaningScopes),
                            styleMeaning: { palette.meaning(for: $0, scopes: effectiveMeaningScopes) },
                            documentTitle: title
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if let problem = live.lastError {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(Face.caption)
                            .foregroundStyle(Ink.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Space.roomy)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // The list follows the page. Marks are in page order, so the one to bring
                // up is the first that is not behind you; past the last mark the list
                // stays at the end rather than springing back to the top.
                .onChange(of: annotator.page) { _, page in
                    let target = shownMarks.first { $0.page >= page } ?? shownMarks.last
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        notes.scrollTo(target.id, anchor: .top)
                    }
                }
                // Jumping to a mark from anywhere else -- the page, the palette -- brings
                // it up here too, so the list and the page never disagree about which
                // mark is being looked at.
                .onChange(of: annotator.selectedMark) { _, mark in
                    guard let mark else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        notes.scrollTo(mark, anchor: .center)
                    }
                }
            }

            if !marks.isEmpty {
                Divider()
                exportBar
            }
        }
        .background(.background.secondary)
        .onAppear { focusNoteInputIfNeeded() }
        .onChange(of: addingNote) { _, isAdding in
            noteInputFocused = false
            if isAdding { focusNoteInputIfNeeded() }
        }
        .confirmationDialog("Remove every mark from this document?",
                            isPresented: $clearing) {
            Button("Remove \(marks.count) marks", role: .destructive) {
                annotator.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes the document without them. It cannot be undone.")
        }
    }

    private func focusNoteInputIfNeeded() {
        guard addingNote else { return }
        DispatchQueue.main.async { noteInputFocused = true }
    }

    /// What the document holds, and the one control that changes what is listed.
    private var summaryBar: some View {
        HStack(spacing: Space.step) {
            Text(filter ?? tally)
                .font(Face.control)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Space.tight)
            Menu {
                Button("All marks") { filter = nil }
                if !meaningsPresent.isEmpty { Divider() }
                ForEach(meaningsPresent, id: \.self) { meaning in
                    Button(meaning) { filter = meaning }
                }
            } label: {
                Image(systemName: filter == nil
                      ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(filter == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .tip("Show only one kind of mark")

            Menu {
                ForEach(availableMeaningScopes) { scope in
                    Button {
                        activeMeaningScope = scope == defaultMeaningScope ? nil : scope
                    } label: {
                        HStack {
                            if scope == currentMeaningScope {
                                Image(systemName: "checkmark")
                            }
                            Text(scope.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "textformat")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("Choose the highlight meanings for this view")

            Button { editingMeaningScope = currentMeaningScope ?? .library } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .tip("Customize the highlight meanings for this scope")
        }
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
        .frame(maxWidth: .infinity)
    }

    /// What leaves the app with these notes, and in what shape. The format is stated
    /// rather than chosen: there is one, and a menu of one is a menu that lies.
    private var exportBar: some View {
        HStack(spacing: Space.step) {
            // A save panel rather than `fileExporter`. The shelf already carries one of
            // those for the bibliography, and a second in the same hierarchy presented
            // nothing at all: the button set its flag and no panel ever appeared.
            Button {
                exportNotes()
            } label: {
                Label("Export as Markdown", systemImage: "square.and.arrow.up")
            }
            .tip("Write these notes to a file")

            Button("Copy all") { copyNotes() }
                .tip("Every mark on this document, as text")

            Spacer(minLength: Space.snug)

            // Only for the document in front of you. Removing every mark means rewriting
            // the file, and the file is not open.
            if documentIsOpen {
                Button(role: .destructive) { clearing = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove every mark from this document")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @State private var clearing = false
    /// Which meaning the list is narrowed to, or nil for all of them.
    @State private var filter: String?
    @FocusState private var noteInputFocused: Bool
    @State private var activeMeaningScope: HighlightMeaningScope?
    @State private var editingMeaningScope: HighlightMeaningScope?

    /// Reading notes as Markdown: the quotations, what was written about them, and where
    /// they are, which is the shape those notes take anywhere else they are pasted.
    private var notesMarkdown: String {
        let exported = marks.map {
            MarkExport(page: $0.page, quoted: $0.quoted, note: $0.note,
                       meaning: palette.meaning(for: $0.colour, scopes: effectiveMeaningScopes))
        }
        return markdownNotes(title: (title as NSString).deletingPathExtension,
                             source: source, marks: exported)
    }

    /// Straight to a save panel, and the file is written here rather than by a document
    /// type the presentation would have had to carry.
    private func exportNotes() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (title as NSString).deletingPathExtension + " notes.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = "Where these notes go"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? notesMarkdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyNotes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notesMarkdown, forType: .string)
    }
}

// MARK: - Page bar

/// Where you are in the document, and how big it is drawn.
///
/// It floats over the page rather than sitting in a bar of its own: the two facts it
/// carries are about the page under it, and a strip along the bottom of the window would
/// cost every document a line of height to say so.
struct PageBar: View {
    var annotator: Annotator
    @Binding var fit: PageFit

    private var total: Int { max(annotator.pageCount, 0) }

    var body: some View {
        if total > 0 {
            HStack(spacing: Space.step) {
                step(-1, "chevron.left", "Previous page")
                Text("\(annotator.page) / \(total)")
                    .font(Face.control.monospacedDigit())
                    .fixedSize()
                step(1, "chevron.right", "Next page")

                Divider().frame(height: 14)

                Menu {
                    Picker("", selection: $fit) {
                        ForEach(PageFit.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } label: {
                    Text(fit.label).font(Face.control)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("How big the page is drawn")

                Divider().frame(height: 14)

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Toggle full screen")
                .tip("Toggle full-screen reading")
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
            .fixedSize()
        }
    }

    private func step(_ delta: Int, _ icon: String, _ what: String) -> some View {
        Button { annotator.go(toPage: annotator.page + delta) } label: {
            Image(systemName: icon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(delta < 0 ? annotator.page <= 1 : annotator.page >= total)
        .accessibilityLabel(what)
        .tip(what)
    }
}

// MARK: - Metadata

// MARK: - Contents

/// Two ways of looking at the same document from the side: what it says it contains, and
/// what its pages look like. A scan carries no outline and a textbook's outline is the
/// fastest way through it, so neither one alone is the rail.
enum ContentsRailMode: String, CaseIterable, Identifiable {
    case outline, thumbnails
    var id: String { rawValue }

    var label: String {
        switch self {
        case .outline: return "Contents"
        case .thumbnails: return "Pages"
        }
    }

    var icon: String {
        switch self {
        case .outline: return "text.alignleft"
        case .thumbnails: return "square.grid.2x2"
        }
    }
}

/// The document's own table of contents, on the page's left where a reader expects it,
/// with its pages as thumbnails behind the same switch.
struct ContentsRail: View {
    var annotator: Annotator
    @Bindable private var prefs = Prefs.shared

    /// The chapter you are inside: the last one that starts at or before the page on
    /// screen. A table of contents that does not say where you are is a list of links.
    private var currentChapter: Annotator.Chapter.ID? {
        annotator.contents.last { ($0.page ?? .max) <= annotator.page }?.id
    }

    /// An outline is only worth offering when the document carries one. Without it the
    /// rail is the pages, and the switch would be a choice between a list and nothing.
    private var hasOutline: Bool { !annotator.contents.isEmpty }

    private var shown: ContentsRailMode { hasOutline ? prefs.contentsRailMode : .thumbnails }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.step) {
                Text(shown.label).font(Face.headline)
                Spacer(minLength: Space.tight)
                if hasOutline {
                    Picker("", selection: $prefs.contentsRailMode) {
                        ForEach(ContentsRailMode.allCases) { mode in
                            Image(systemName: mode.icon)
                                .accessibilityLabel(mode.label)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .tip("The chapters, or the pages themselves")
                }
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            switch shown {
            case .outline: outline
            case .thumbnails: PageThumbnails(view: annotator.view)
            }
        }
        .background(.background.secondary)
    }

    private var outline: some View {
        ScrollViewReader { rail in
            outlineList
                // The rail follows the page too: a chapter marked as the one you are in,
                // scrolled off the top of its own list, is a highlight nobody can see.
                .onChange(of: currentChapter) { _, chapter in
                    guard let chapter else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        rail.scrollTo(chapter, anchor: .center)
                    }
                }
        }
    }

    private var outlineList: some View {
        List(annotator.contents, selection: .constant(currentChapter)) { chapter in
            Button {
                annotator.go(to: chapter)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.snug) {
                    // The same two sizes the sidebar uses for a row and its count:
                    // a chapter is a place you can go, exactly as a shelf is.
                    Text(chapter.label)
                        .font(chapter.level == 0 ? Face.body.weight(.medium) : Face.caption)
                        .foregroundStyle(chapter.level == 0 ? .primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: Space.tight)
                    if let page = chapter.page {
                        Text("\(page)")
                            .font(Face.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                // Depth by indent: a table of contents is read straight down far more
                // often than it is folded.
                .padding(.leading, CGFloat(chapter.level) * 11)
                .padding(.horizontal, Space.snug)
                .padding(.vertical, Space.tight)
                .contentShape(Rectangle())
                .background(chapter.id == currentChapter
                            ? Color.accentColor.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: Metric.control))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// The document's pages, drawn by PDFKit's own thumbnail view and wired straight to the
/// page on screen: clicking one turns to it, and turning a page moves the selection here.
struct PageThumbnails: NSViewRepresentable {
    let view: PDFView?

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.thumbnailSize = NSSize(width: 92, height: 122)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.backgroundColor = .clear
        thumbnails.pdfView = view
        return thumbnails
    }

    func updateNSView(_ thumbnails: PDFThumbnailView, context: Context) {
        // Identity, not equality: a new document means a new `PDFView`, and reassigning
        // the same one makes the thumbnail view rebuild every page for nothing.
        if thumbnails.pdfView !== view { thumbnails.pdfView = view }
    }
}
