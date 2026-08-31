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
    // Computed, not stored: a stored private property makes the memberwise initialiser
    // private too, and the delegate is the one that builds this window.
    private var palette: Palette { Palette.shared }
    private var prefs: Prefs { Prefs.shared }

    private var passwords: [String] { PasswordList.active(prefs.passwords) }

    var body: some View {
        VStack(spacing: 0) {
            PDFPreview(url: url, passwords: passwords, annotator: annotator, fit: fit)
                .overlay(alignment: .top) { selectionBar }
                .inspector(isPresented: $showsNotes) {
                    NotesRail(annotator: annotator, palette: palette,
                              addingNote: $addingNote, noteText: $noteText,
                              lastColour: nextColour, title: title, source: url.path,
                              close: { showsNotes = false })
                    .inspectorColumnWidth(min: SplitLayout.panelFloor, ideal: 320)
                }
            Divider()
            HStack(spacing: Space.roomy) {
                PageBar(annotator: annotator, fit: $fit)
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
        // The five highlighters and a note, without a menu and without the shelf's command
        // table: this window has no scopes to resolve, so it reads the keys directly.
        .onKeyPress(phases: .down) { press in mark(with: press) }
        .onDisappear { annotator.flush() }
    }

    private var title: String {
        annotator.statedTitle?.isEmpty == false ? annotator.statedTitle! : url.lastPathComponent
    }

    private var nextColour: NSColor {
        (palette.styles.first { $0.id.uuidString == prefs.lastHighlightColour }
            ?? palette.styles.first)?.nsColor ?? .systemYellow
    }

    /// The bar that appears beside a selection. The keys are the fast path; this is the one
    /// somebody finds without being told, which is why both exist and why this can be
    /// switched off once you no longer need it.
    @ViewBuilder
    private var selectionBar: some View {
        if prefs.selectionPalette, annotator.hasSelection {
            HStack(spacing: Space.step) {
                ForEach(palette.styles) { style in
                    Button {
                        _ = annotator.highlightSelection(colour: style.nsColor)
                        prefs.lastHighlightColour = style.id.uuidString
                    } label: {
                        Circle().fill(Color(style.nsColor)).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(palette.meaning(for: style.nsColor))
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
              palette.styles.indices.contains(digit - 1) else { return .ignored }
        let style = palette.styles[digit - 1]
        _ = annotator.highlightSelection(colour: style.nsColor)
        prefs.lastHighlightColour = style.id.uuidString
        return .handled
    }
}
