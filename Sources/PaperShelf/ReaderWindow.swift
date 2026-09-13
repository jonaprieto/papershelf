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

    @State private var annotator = Annotator()
    @State private var fit: PageFit = .width
    @State private var presentation = false
    @State private var presentationFit: PageFit?
    @State private var presentationWindow: NSWindow?
    @State private var noteText = ""
    @State private var addingNote = false
    @State private var writingNote = false
    @State private var showsNotes = false
    /// The page the library remembers, when it answered too late to move the page under a
    /// reader who had already started. Offered rather than applied.
    @State private var resumeAt: Int?
    /// The row this file has in the library, made when it is opened. Opening records; it
    /// never renames, moves or files anything.
    @State private var documentID: String?
    @State private var documentProjectScopes: [HighlightMeaningScope] = []
    @State private var readerWindow = PaneWindow()
    // Computed, not stored: a stored private property makes the memberwise initialiser
    // private too, and the delegate is the one that builds this window.
    private var palette: Palette { Palette.shared }
    private var prefs: Prefs { Prefs.shared }

    private var passwords: [String] { PasswordList.active(prefs.passwords) }

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
                    if let resumeAt {
                        Button("Resume at p. \(resumeAt)") {
                            annotator.go(toPage: resumeAt)
                            self.resumeAt = nil
                        }
                        .buttonStyle(.link)
                        .font(Face.caption)
                    }
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
        .task { await recordAndRestore() }
        .task(id: annotator.page) { await rememberPage() }
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

    /// Opening a file records it and asks where you were.
    ///
    /// The page is already on screen by the time any of this runs: nothing here is on the
    /// path between double-clicking a file and seeing it. A position that comes back while
    /// the document is still on its first page is applied; one that comes back after the
    /// reader has moved is offered in the bar instead, because a page that jumps under
    /// somebody reading it is worse than a page they have to ask to return to.
    private func recordAndRestore() async {
        guard let library = Library.shared else { return }
        let resolved = url.resolvingSymlinksInPath()
        // Off the main actor: this parses the document for its title, author and page
        // count, which is a tenth of a second on a long paper.
        let input = await Task.detached { indexInput(for: resolved) }.value
        // Split rather than coalesced with ??: an autoclosure cannot carry an await.
        var record = try? await library.document(atPath: resolved.path)
        if record == nil {
            record = (try? await library.indexDocuments([input]))?.first
        }
        guard let record else { return }
        documentID = record.id
        annotator.setDocumentID(record.id)
        let projects = (try? await library.projects(containingDocument: record.id)) ?? []
        documentProjectScopes = projects.map { .project(id: $0.id, name: $0.name) }

        guard let position = try? await library.readingPosition(forDocument: record.id),
              position.page > 1 else { return }
        // The page has to exist before it can be turned to, and the document is read on a
        // background queue. Waited for rather than assumed, and given up on: a file that
        // takes longer than this to parse is one whose reader is already looking at page 1.
        for _ in 0..<20 {
            if annotator.hasPages { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard annotator.hasPages, !Task.isCancelled else { return }
        if annotator.page <= 1 {
            annotator.go(toPage: position.page)
        } else {
            resumeAt = position.page
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { resumeAt = nil }
        }
    }

    /// Where you are, kept for next time. Debounced, because turning ten pages is one
    /// place to come back to, not ten.
    private func rememberPage() async {
        guard let documentID, annotator.hasPages else { return }
        // An offer to go back is stale the moment you turn a page yourself.
        if resumeAt != nil, annotator.page > 1 { resumeAt = nil }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, let library = Library.shared else { return }
        try? await library.rememberReadingPosition(documentID: documentID,
                                                   page: annotator.page,
                                                   pageCount: annotator.pageCount)
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
        let style = currentStyles[slot]
        _ = annotator.highlightSelection(colour: style.nsColor)
        prefs.lastHighlightColour = style.id.uuidString
        return .handled
    }
}
