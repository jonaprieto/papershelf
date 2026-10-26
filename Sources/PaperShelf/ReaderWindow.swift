import SwiftUI
import AppKit
import PaperShelfCore

extension Notification.Name {
    static let readingFileRemoved = Notification.Name("PaperShelf.readingFileRemoved")
}

/// A window that is a page.
///
/// The library window has to know about sources, scans, watchers and a shelf before it can
/// show anything. None of that is needed to read a file somebody double-clicked in Finder,
/// so this window knows about three things: the file, an `Annotator`, and the palette of
/// highlighters. Nothing here touches `Runner` or `Covers`, which is what lets the app open
/// a PDF without building a library first.
struct ReaderWindow: View {
    let url: URL

    @State private var annotator = Annotator(opensToRead: true)
    @State private var fit: PageFit = .width
    @State private var presentation = false
    @State private var presentationFit: PageFit?
    @State private var presentationWindow: NSWindow?
    @State private var noteText = ""
    @State private var addingNote = false
    @State private var writingNote = false
    @State private var showsNotes = false
    @State private var showingPalette = false
    @State private var passwordPurpose: PasswordSheet.Purpose?
    /// The row this file has in the library, made when it is opened. Opening records; it
    /// never renames, moves or files anything.
    @State private var documentID: String?
    @State private var documentProjectScopes: [HighlightMeaningScope] = []
    @State private var readerWindow = PaneWindow()
    // Computed, not stored: a stored private property makes the memberwise initialiser
    // private too, and the delegate is the one that builds this window.
    private var palette: Palette { Palette.shared }
    private var prefs: Prefs { Prefs.shared }

    private var passwords: [String] { prefs.pdfPasswords }

    var body: some View {
        VStack(spacing: 0) {
            DocumentPane(
                url: url,
                passwords: passwords,
                annotator: annotator,
                fit: $fit,
                appearance: prefs.readingAppearance,
                presentation: presentation,
                showsContentsRail: !presentation && prefs.contentsShown && annotator.hasPages,
                // This window keeps its page controls in the row underneath, with the
                // filename beside them, so it asks for no bar over the page.
                showsPageBar: false,
                onPageStep: presentation && prefs.leftRightTurnsPages
                    ? { annotator.go(toPage: annotator.page + $0) } : nil,
                onMarkClick: selectMark(at:),
                openFind: openFind
            ) {
                selectionBar
            }
            .inspector(isPresented: $showsNotes) {
                NotesRail(annotator: annotator, palette: palette,
                          addingNote: $addingNote, noteText: $noteText,
                          lastColour: nextColour, title: title, source: url.path,
                          close: { showsNotes = false }, isWritingNote: $writingNote,
                          documentID: documentID,
                          effectiveProjectScopes: documentProjectScopes)
                .inspectorColumnWidth(min: SplitLayout.panelFloor, ideal: 320)
            }
            if !presentation {
                Divider()
                HStack(spacing: Space.roomy) {
                    PageBar(annotator: annotator, fit: $fit, openFind: openFind,
                            presentation: presentation, togglePresentation: togglePresentation)
                    notesButton
                    paletteButton
                    Spacer()
                    Text(url.lastPathComponent)
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, Space.roomy)
                .padding(.vertical, Space.tight)
            }
        }
        .navigationTitle(title)
        .preferredColorScheme(prefs.appearance.colorScheme)
        .focusedValue(\.findInPDF, FindInPDFAction(perform: openFind))
        .focusedValue(\.togglePane, TogglePaneAction { showsNotes.toggle() })
        .focusedValue(\.undoMark, UndoMarkAction { annotator.undoLastMarkChange() })
        .frame(minWidth: SplitLayout.readerFloorWidth,
               minHeight: SplitLayout.readerFloorHeight)
        .background { WindowReader { readerWindow.window = $0 }.frame(width: 0, height: 0) }
        .onReceive(NotificationCenter.default.publisher(for: .printPDF)) { note in
            guard let window = note.object as? NSWindow, window === readerWindow.window else { return }
            annotator.printPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFSearch)) { note in
            guard let window = note.object as? NSWindow, window === readerWindow.window else { return }
            openFind()
        }
        .onReceive(NotificationCenter.default.publisher(for: .windowCommand)) { note in
            guard let window = note.object as? NSWindow, window === readerWindow.window,
                  let raw = note.userInfo?["command"] as? String,
                  let command = Command(rawValue: raw) else { return }
            perform(command)
        }
        .sheet(isPresented: $showingPalette) {
            CommandPalette(commands: Self.paletteCommands, documents: [],
                           run: perform, open: { _ in }, sources: paletteSources)
        }
        .sheet(item: $passwordPurpose) { purpose in
            PasswordSheet(purpose: purpose, annotator: annotator)
        }
        .task { await record() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard presentation, let window = note.object as? NSWindow,
                  let presentationWindow, window === presentationWindow
            else { return }
            leavePresentation()
        }
        // The five highlighters and a note, without a menu and without the shelf's command
        // table: this window has no scopes to resolve, so it reads the keys directly.
        .onKeyPress(phases: .down) { press in
            if writingNote { return .ignored }
            if let command = Command.pageActions.first(where: {
                Keymap.shared.shortcut(for: $0)?.matches(press) == true
            }), command.performPageAction(on: annotator, fit: $fit) {
                return .handled
            }
            if Keymap.shared.shortcut(for: .findInDocument)?.matches(press) == true {
                openFind()
                return .handled
            }
            return mark(with: press)
        }
        .onDisappear { annotator.flush() }
        .onReceive(NotificationCenter.default.publisher(for: .readingFileRemoved)) { note in
            guard let removed = note.object as? URL,
                  removed.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { return }
            readerWindow.window?.close()
        }
    }

    /// Opening a file records it, so its marks, notes and projects have an owner.
    ///
    /// Where you were is the annotator's to restore and remember, as it is for a paper
    /// read in the library. This window did both a second time: two writes for every
    /// page turned, and an offer to resume at the page the annotator had already turned to.
    private func record() async {
        guard let library = Library.shared else { return }
        let resolved = url.resolvingSymlinksInPath()
        // Split rather than coalesced with ??: an autoclosure cannot carry an await.
        var record = try? await library.document(atPath: resolved.path)
        if record == nil {
            // Off the main actor, and only for a paper the library has not met: this
            // parses the whole document a second time for its title, author and page
            // count, which is a tenth of a second on a long paper.
            let input = await Task.detached { indexInput(for: resolved) }.value
            record = (try? await library.indexDocuments([input]))?.first
        }
        guard let record else { return }
        documentID = record.id
        annotator.setDocumentID(record.id)
        let projects = (try? await library.projects(containingDocument: record.id)) ?? []
        documentProjectScopes = projects.map { .project(id: $0.id, name: $0.name) }
    }

    /// What one paper can do with no library window behind it.
    static let paletteCommands: [Command] = Command.pageActions + [
        .highlight1, .highlight2, .highlight3, .highlight4, .highlight5,
        .addNote, .addBookmark, .removeBookmark, .showBookmarks, .nextMark, .previousMark,
        .findInDocument, .toggleNotes, .toggleContents, .zenMode,
        .printPDF, .lockPDF, .unlockPDF, .openExternally, .revealInFinder, .openFile, .shortcuts,
    ]

    /// Every command this window answers, from its palette, its menu items and its keys.
    private func perform(_ command: Command) {
        if command.performPageAction(on: annotator, fit: $fit) { return }
        switch command {
        case .palette: showingPalette = true
        case .highlight1: highlight(slot: 0)
        case .highlight2: highlight(slot: 1)
        case .highlight3: highlight(slot: 2)
        case .highlight4: highlight(slot: 3)
        case .highlight5: highlight(slot: 4)
        case .addNote:
            guard annotator.hasSelection || annotator.selectedMark != nil else { return }
            showsNotes = true
            addingNote = true
            writingNote = true
        case .addBookmark: _ = annotator.toggleBookmark()
        case .removeBookmark:
            if let bookmark = annotator.bookmarkOnCurrentPage { _ = annotator.removeBookmark(bookmark) }
        case .showBookmarks:
            prefs.contentsShown = true
            prefs.contentsRailMode = .bookmarks
        case .nextMark: stepMark(by: 1)
        case .previousMark: stepMark(by: -1)
        case .findInDocument: openFind()
        case .toggleNotes: showsNotes.toggle()
        case .toggleContents: prefs.contentsShown.toggle()
        case .zenMode: togglePresentation()
        case .printPDF: annotator.printPDF()
        case .lockPDF: passwordPurpose = .lock
        case .unlockPDF: passwordPurpose = .unlock
        case .openExternally: NSWorkspace.shared.open(url)
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openFile: AppDelegate.current?.choosePDFs()
        case .shortcuts:
            prefs.settingsPane = .keyboard
            PaletteSettings.openSettingsWindow()
        default: break
        }
    }

    private func highlight(slot: Int) {
        guard annotator.hasSelection, currentStyles.indices.contains(slot) else { return }
        let style = currentStyles[slot]
        _ = annotator.highlightSelection(colour: style.nsColor)
        prefs.lastHighlightColour = style.id.uuidString
    }

    private func stepMark(by delta: Int) {
        guard !annotator.marks.isEmpty else { return }
        let current = annotator.marks.firstIndex { $0.id == annotator.selectedMark }
        let next = ((current ?? (delta > 0 ? -1 : 0)) + delta + annotator.marks.count)
            % annotator.marks.count
        annotator.jump(to: annotator.marks[next])
    }

    /// This paper's passages and pages, and the library's other papers, each opening in a
    /// reader of its own.
    private var paletteSources: PaletteSources {
        PaletteSources(
            inTheLibrary: { text in
                await PaletteSources.libraryDocuments(matching: text) { path in
                    AppDelegate.current?.openReader(for: URL(fileURLWithPath: path))
                }
            },
            inThisDocument: { text in
                annotator.find(text).map { hit in
                    PageHit(id: "doc-\(hit.page)-\(hit.line.prefix(24))", page: hit.page,
                            line: hit.line, go: hit.jump)
                }
            },
            goToPage: { annotator.go(toPage: $0) },
            help: { perform(.shortcuts) }
        )
    }

    /// The notes beside the page, and how many there are. Without it a reader opened from
    /// Finder showed its notes only to somebody who selected text or clicked a highlight.
    private var notesButton: some View {
        Button { showsNotes.toggle() } label: {
            Label(annotator.marks.isEmpty ? "Notes" : "\(annotator.marks.count)",
                  systemImage: "highlighter")
                .font(Face.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(showsNotes ? Color.accentColor : .secondary)
        .accessibilityLabel(showsNotes ? "Hide the notes" : "Show the notes")
        .tip(showsNotes ? "Hide the notes" : "Highlights and notes in this PDF", command: .toggleNotes)
    }

    /// The palette's key, on screen. Nothing in this window said ⌘K existed.
    private var paletteButton: some View {
        Button { showingPalette = true } label: {
            Label(Keymap.shared.shortcut(for: .palette)?.display ?? "Commands",
                  systemImage: "magnifyingglass")
                .font(Face.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Open command palette")
        .tip("Search this paper or the library, or run any command", command: .palette)
    }

    private var title: String {
        annotator.statedTitle?.isEmpty == false ? annotator.statedTitle! : url.lastPathComponent
    }

    private var nextColour: NSColor {
        (currentStyles.first { $0.id.uuidString == prefs.lastHighlightColour }
            ?? currentStyles.first)?.nsColor ?? .systemYellow
    }

    private var currentMeaningScopes: [HighlightMeaningScope] {
        [.forDocument(url, id: documentID),
         .forFolder(url.deletingLastPathComponent()), .library]
    }

    private var currentStyles: [HighlightStyle] {
        palette.styles(for: currentMeaningScopes)
    }

    private func selectMark(at point: CGPoint) {
        guard let mark = annotator.mark(atViewPoint: point) else { return }
        annotator.selectedMark = mark.id
        showsNotes = true
    }

    private func openFind() {
        annotator.openFind()
        guard annotator.showsFind else { return }
        prefs.contentsShown = true
        prefs.contentsRailMode = .find
    }

    private func togglePresentation() {
        if presentation {
            presentationWindow?.toggleFullScreen(nil)
            leavePresentation()
            return
        }
        guard let window = NSApp.keyWindow else { return }
        presentationFit = fit
        fit = .page
        showsNotes = false
        presentation = true
        presentationWindow = window
        window.toggleFullScreen(nil)
    }

    private func leavePresentation() {
        presentation = false
        if let presentationFit { fit = presentationFit }
        presentationFit = nil
        presentationWindow = nil
    }

    /// The bar that appears beside a selection. The keys are the fast path; this is the one
    /// somebody finds without being told, which is why both exist and why this can be
    /// switched off once you no longer need it.
    ///
    /// The pane hands an overlay the page's top-leading corner, so the bar asks for the
    /// page's width to sit centred over it as it always has. Width only: a height as well
    /// would centre it vertically and park it halfway down the page.
    @ViewBuilder
    private var selectionBar: some View {
        if prefs.selectionPalette, annotator.hasSelection {
            HStack(spacing: Space.step) {
                ForEach(currentStyles) { style in
                    Button {
                        _ = annotator.highlightSelection(colour: style.nsColor)
                        prefs.lastHighlightColour = style.id.uuidString
                    } label: {
                        Circle().fill(Color(style.nsColor)).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(palette.meaning(for: style.nsColor, scopes: currentMeaningScopes))
                }
                Divider().frame(height: 14)
                AskReadingAssistant {
                    guard let selection = annotator.selectionForHandoff() else { return nil }
                    return ChatGPTHandoff.prompt(quoted: selection.quoted, note: "",
                                                 page: selection.page, title: selection.title)
                }
                Button {
                    showsNotes = true
                    addingNote = true
                    writingNote = true
                } label: {
                    Label("Note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .tip("Add a note to the selection", command: .addNote)
                Button {
                    _ = annotator.toggleBookmark()
                } label: {
                    Image(systemName: annotator.bookmarkOnCurrentPage == nil
                          ? "bookmark" : "bookmark.fill")
                }
                .buttonStyle(.plain)
                .help(annotator.bookmarkOnCurrentPage == nil
                      ? "Bookmark this page" : "Remove the bookmark from this page")
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.snug)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .padding(.top, Space.roomy)
            .frame(maxWidth: .infinity, alignment: .top)
            .transition(.opacity)
        }
    }

    /// 1 to 5 paint with the palette's colours, N opens a note on the selection. Keys with
    /// no selection under them are left alone, so typing in a field the inspector owns
    /// still types.
    private func mark(with press: KeyPress) -> KeyPress.Result {
        guard annotator.hasSelection else { return .ignored }
        if Keymap.shared.shortcut(for: .addNote)?.matches(press) == true {
            showsNotes = true
            addingNote = true
            writingNote = true
            return .handled
        }
        let highlights: [Command] = [.highlight1, .highlight2, .highlight3, .highlight4, .highlight5]
        guard let slot = highlights.firstIndex(where: { Keymap.shared.shortcut(for: $0)?.matches(press) == true }),
              currentStyles.indices.contains(slot) else { return .ignored }
        highlight(slot: slot)
        return .handled
    }
}
