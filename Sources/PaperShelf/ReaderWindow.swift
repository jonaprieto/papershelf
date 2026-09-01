import SwiftUI
import AppKit
import PDFKit
import PaperShelfCore

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
    @State private var noteText = ""
    @State private var addingNote = false
    @State private var showsNotes = false
    /// The page the library remembers, when it answered too late to move the page under a
    /// reader who had already started. Offered rather than applied.
    @State private var resumeAt: Int?
    /// The row this file has in the library, made when it is opened. Opening records; it
    /// never renames, moves or files anything.
    @State private var documentID: String?
    @State private var documentProjectScopes: [HighlightMeaningScope] = []
    // Computed, not stored: a stored private property makes the memberwise initialiser
    // private too, and the delegate is the one that builds this window.
    private var palette: Palette { Palette.shared }
    private var prefs: Prefs { Prefs.shared }

    private var passwords: [String] { PasswordList.active(prefs.passwords) }

    var body: some View {
        VStack(spacing: 0) {
            PDFPreview(url: url, passwords: passwords, annotator: annotator, fit: fit,
                       onMarkClick: selectMark(at:))
                .overlay(alignment: .top) { selectionBar }
                .inspector(isPresented: $showsNotes) {
                    NotesRail(annotator: annotator, palette: palette,
                              addingNote: $addingNote, noteText: $noteText,
                              lastColour: nextColour, title: title, source: url.path,
                              close: { showsNotes = false }, documentID: documentID,
                              effectiveProjectScopes: documentProjectScopes)
                    .inspectorColumnWidth(min: SplitLayout.panelFloor, ideal: 320)
                }
            Divider()
            HStack(spacing: Space.roomy) {
                PageBar(annotator: annotator, fit: $fit)
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
        .navigationTitle(title)
        .frame(minWidth: 520, minHeight: 400)
        .task { await recordAndRestore() }
        .task(id: annotator.page) { await rememberPage() }
        // The five highlighters and a note, without a menu and without the shelf's command
        // table: this window has no scopes to resolve, so it reads the keys directly.
        .onKeyPress(phases: .down) { press in mark(with: press) }
        .onDisappear { annotator.flush() }
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

    /// The bar that appears beside a selection. The keys are the fast path; this is the one
    /// somebody finds without being told, which is why both exist and why this can be
    /// switched off once you no longer need it.
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
                Button {
                    showsNotes = true
                    addingNote = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("Note on the selection")
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.snug)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .padding(.top, Space.roomy)
            .transition(.opacity)
        }
    }

    /// 1 to 5 paint with the palette's colours, N opens a note on the selection. Keys with
    /// no selection under them are left alone, so typing in a field the inspector owns
    /// still types.
    private func mark(with press: KeyPress) -> KeyPress.Result {
        guard annotator.hasSelection, press.modifiers.isEmpty else { return .ignored }
        if press.key == KeyEquivalent("n") {
            showsNotes = true
            addingNote = true
            return .handled
        }
        guard let digit = Int(press.characters), (1...5).contains(digit),
              currentStyles.indices.contains(digit - 1) else { return .ignored }
        let style = currentStyles[digit - 1]
        _ = annotator.highlightSelection(colour: style.nsColor)
        prefs.lastHighlightColour = style.id.uuidString
        return .handled
    }
}
