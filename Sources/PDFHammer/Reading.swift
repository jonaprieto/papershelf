import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

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
    /// Named in the handoff so an answer is about the right document.
    var documentTitle: String = ""

    @State private var editing = false
    @State private var text = ""

    /// The colour it was actually painted with, whatever palette that came from.
    private var colour: Color { Color(nsColor: mark.colour ?? .systemYellow) }

    private var handoffPrompt: String {
        ChatGPTHandoff.prompt(quoted: mark.quoted, note: mark.note, page: mark.page,
                              title: documentTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Menu {
                    ForEach(styles) { style in
                        Button { recolour(style.nsColor) } label: {
                            Label(style.meaning.isEmpty ? "Unnamed" : style.meaning,
                                  systemImage: "circle.fill")
                        }
                    }
                } label: {
                    Circle()
                        .fill(colour)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .padding(.top, 2)
                .tip(meaning)

                VStack(alignment: .leading, spacing: 3) {
                    if !mark.quoted.isEmpty {
                        // The quote carries the highlight it has on the page. A swatch
                        // says which colour; this says what the page looks like.
                        Text(mark.quoted)
                            .font(.callout)
                            .lineLimit(3)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(colour.opacity(0.38), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if !mark.note.isEmpty && !editing {
                        Text(mark.note).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    HStack(spacing: 5) {
                        Text("page \(mark.page)")
                        if !meaning.isEmpty && meaning != "Highlight" {
                            Text("·")
                            Text(meaning).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)

                if ChatGPTHandoff.isInstalled, !mark.quoted.isEmpty || !mark.note.isEmpty {
                    Menu {
                        Button("Open in ChatGPT") {
                            ChatGPTHandoff.open(handoffPrompt)
                        }
                        Button("Copy for ChatGPT") {
                            ChatGPTHandoff.copy(handoffPrompt)
                        }
                    } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
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
                .foregroundStyle(.tertiary)
                .tip(mark.note.isEmpty ? "Add a note here" : "Edit this note")
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .tip("Remove this mark from the file")
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
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: jump)
    }
}

/// The marks beside the page. A window-level pane like the sidebar, not part of the
/// inspector: nesting it inside a column that is already width-constrained made the two
/// of them overflow the frame and draw over the browser.
struct NotesRail: View {
    @ObservedObject var annotator: Annotator
    @ObservedObject var palette: Palette
    @Binding var addingNote: Bool
    @Binding var noteText: String
    let lastColour: NSColor
    let title: String
    let source: String
    let close: () -> Void
    /// Its own bar, with the count, the export menu and the way out. Off when it sits in
    /// the inspector, which already has one of those and does not need two.
    var showsHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
            HStack {
                Text("Notes").font(.callout.weight(.semibold))
                Spacer()
                Text("\(annotator.marks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !annotator.marks.isEmpty {
                    Menu {
                        Button("Copy as Markdown") { copyNotes() }
                        Button("Save as Markdown…") { exporting = true }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .tip("Export these notes")

                    Button(role: .destructive) { clearing = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Ink.red)
                    .help("Remove every mark from this document")
                }
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .tip("Hide the notes", key: "⌘⇧N")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if addingNote {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Note on the selection")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("What is worth remembering", text: $noteText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...5)
                            HStack {
                                Button("Save") {
                                    annotator.highlightSelection(colour: lastColour, note: noteText)
                                    noteText = ""
                                    addingNote = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { noteText = ""; addingNote = false }
                            }
                        }
                        Divider()
                    }

                    if annotator.marks.isEmpty && !addingNote {
                        Text("Select text on the page to highlight it or attach a note.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(annotator.marks) { mark in
                        MarkRow(
                            mark: mark,
                            isSelected: annotator.selectedMark == mark.id,
                            jump: { annotator.jump(to: mark) },
                            remove: { annotator.remove(mark) },
                            save: { annotator.setNote($0, on: mark) },
                            recolour: { annotator.setColour($0, on: mark) },
                            styles: palette.styles,
                            meaning: palette.meaning(for: mark.colour),
                            documentTitle: title
                        )
                    }

                    if let problem = annotator.lastError {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Ink.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background.secondary)
    }


    @State private var clearing = false
    @State private var exporting = false

    /// Reading notes as Markdown: the quotations, what was written about them, and where
    /// they are, which is the shape those notes take anywhere else they are pasted.
    private var notesMarkdown: String {
        markdownNotes(
            title: (title as NSString).deletingPathExtension,
            source: source,
            marks: annotator.marks.map {
                MarkExport(page: $0.page, quoted: $0.quoted, note: $0.note,
                           meaning: palette.meaning(for: $0.colour))
            }
        )
    }

    private func copyNotes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notesMarkdown, forType: .string)
    }
}

// MARK: - Metadata

// MARK: - Contents

/// The document's own table of contents, on the page's left where a reader expects it.
/// Only offered when the PDF actually carries an outline.
struct ContentsRail: View {
    @ObservedObject var annotator: Annotator
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Contents").font(.callout.weight(.semibold))
                Spacer()
                Text("\(annotator.contents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .tip("Hide the contents", key: "⌘⇧T")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .background(.bar)

            Divider()

            List(annotator.contents) { chapter in
                Button {
                    annotator.go(to: chapter)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(chapter.label)
                            .font(chapter.level == 0 ? .callout.weight(.medium) : .caption)
                            .foregroundStyle(chapter.level == 0 ? .primary : .secondary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let page = chapter.page {
                            Text("\(page)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Depth by indent: a table of contents is read straight down far more
                    // often than it is folded.
                    .padding(.leading, CGFloat(chapter.level) * 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .listStyle(.inset)
        }
        .background(.background.secondary)
    }
}
