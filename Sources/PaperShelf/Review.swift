import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PaperShelfCore

struct ReviewInspector: View {
    /// Return in the name field renames the file on disk. Off means it confirms the name
    /// into the plan instead, to be applied with everything else later.
    /// Not `private`: the BibTeX side of this inspector lives in BibtexPanel.swift,
    /// and `private` is file-scoped.
    @Bindable var prefs = Prefs.shared

    /// Whether the page is one of the panes here.
    ///
    /// The shelf, the bibliography and the duplicates view are about a collection; the
    /// page belongs to the two places that are about one document -- the reviewer and the
    /// reader. Showing it everywhere is what gave a shelf of covers half a window of PDF
    /// nobody asked to see.
    let showsPage: Bool
    /// How much room this whole region has. What folds is decided from it rather than
    /// from the window, since the sidebar and the browser have already taken their share.
    let paneWidth: CGFloat
    let item: Item
    var runner: Runner
    let passwords: [String]
    @Binding var draft: String
    @FocusState.Binding var editing: Bool
    let confirm: () -> Void
    let skip: () -> Void
    let skipFolder: () -> Void
    let applyNow: () -> Void
    let identify: () -> Void
    let copyCitation: () -> Void
    /// A raw exchange with the model, for correcting one entry. A closure because the
    /// client lives with the view that owns the settings, not with this one.
    let improveCitation: (String, String) async throws -> String
    let moveTo: () -> Void
    let aiReady: Bool
    let markDeleted: () -> Void
    let reopen: () -> Void
    /// Opens this document in the reader: the page, its outline and the marks on it, with
    /// the browser out of the way. The shelf draws no page of its own, so this is the way
    /// from a cover to what is inside it.
    let read: () -> Void
    /// Set only while the reader is open, and the way back out of it. ⎋ does the same
    /// thing; a button is here because a way in that has no visible way out is a trap.
    var leaveReader: (() -> Void)?
    let reset: () -> Void
    let leaveField: () -> Void
    let excerpt: String?

    /// This file's tags, so the Details panel can show and change them.
    var tags: TagActions = .none

    var annotator: Annotator
    var palette: Palette

    // The bibliography entry for this one file, edited in place. See BibtexPanel.swift.
    /// The same preference the bibliography tab uses, so one entry is never judged by a
    /// different standard from the file it will end up in.

    /// Where a per-entry improvement would be sent, so the confirmation can say it. The
    /// same key the rest of the app reads, never a copy of the string.

    @State var citationDraft = ""
    /// Non-nil while the confirmation for a single entry is up. Every other billed call in
    /// the app asks first; this one did not.
    @State var confirmingImprove = false
    /// The entry as it is kept with the document, or empty when nothing is.
    ///
    /// Not a `citationStored` flag. A flag was set when Store succeeded and cleared only
    /// when something in code replaced the draft, so typing in the editor left it saying
    /// "Stored" over an entry that no longer matched what was stored, with the button
    /// disabled and no way to keep the edit.
    @State var storedCitation = ""
    /// The mark the pointer is over, by id rather than by value: recolouring rewrites the
    /// entry in `marks`, and a copy held here would go on describing the old colour.
    @State private var hoveredMarkID: UUID?
    /// Holds the bar up for a moment after the pointer leaves the mark, so it can be
    /// reached. Without it the bar is gone before the pointer arrives at it.
    @State private var markBarHide: Task<Void, Never>?
    @State var citationImproving = false
    @State var citationImprovedByAI = false
    @State var citationNote: String?
    /// How tall the entry is, measured by the editor that draws it.
    @State var citationHeight: CGFloat = 40
    @Environment(\.colorScheme) private var colourScheme
    private var isDark: Bool { colourScheme == .dark }
    @State private var addingNote = false
    @State private var noteText = ""
    @State private var hovered: UUID?
    @State private var hoveringNote = false
    @State private var hoveringChatGPT = false

    private var lastStyle: HighlightStyle? {
        palette.styles.first { $0.id.uuidString == prefs.lastHighlightColour } ?? palette.styles.first
    }

    private var hoveredMeaning: String? {
        guard let hovered, let style = palette.styles.first(where: { $0.id == hovered })
        else { return nil }
        return style.meaning.isEmpty ? "Unnamed highlighter" : style.meaning
    }

    /// Whether the panel is drawn at all. Only the switch that names it decides this.
    ///
    /// It used to be `!collapsed && !reading`, which meant the toolbar's inspector button,
    /// ⌥⌘I and ⌘⇧N all did nothing while reading: the mode hid the panel, so flipping the
    /// switch changed a value nothing was reading. Reading mode puts the panel away by
    /// entering (see `Chrome.toggleReading`) rather than by holding it shut.
    private var showsPanel: Bool { !prefs.inspectorCollapsed }

    /// Below `SplitLayout.inspectorOverlaysBelow` the panel is drawn over the page rather
    /// than beside it. Nothing is lost at a narrow width; it stops costing the page room
    /// it does not have, which is what lets the window reach 640 points.
    private var panelOverlays: Bool { SplitLayout.inspectorOverlays(paneWidth: paneWidth) }

    /// Below `SplitLayout.contentsFoldsBelow` the outline is a popover under its own
    /// toolbar button instead of a third column.
    private var contentsIsPopover: Bool { SplitLayout.contentsIsPopover(paneWidth: paneWidth) }

    private var hasContents: Bool { annotator.hasPages }

    private var decision: Decision? { runner.decision(for: item) }
    private var isEdited: Bool { sanitizedFilename(draft) != item.destinationName }

    private var pendingInFolder: Int { runner.pendingInFolder(of: item) }

    private var folderName: String {
        let folder = (item.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "this folder" : (folder as NSString).lastPathComponent
    }

    private var folderScopeLabel: String {
        pendingInFolder > 0 ? "Skip folder (\(pendingInFolder))" : "Skip folder"
    }

    /// Just the folder. The filename is already on screen twice, in the field and in the
    /// "was" line under it.
    private var folderPath: String {
        let folder = (item.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "in the selected folder" : folder + "/"
    }

    /// The marks on this document, inside the inspector rather than in a column of its
    /// own. It was a fixed 240 points that the window's minimum width had to reserve for
    /// whether or not anyone had opened it; here it costs nothing until it is asked for.
    private var notesPanel: some View {
        NotesRail(annotator: annotator, palette: palette,
                  addingNote: $addingNote, noteText: $noteText,
                  lastColour: (palette.styles.first ?? Palette.defaults[0]).nsColor,
                  title: item.destinationName,
                  source: item.currentURL.path,
                  close: {},
                  showsHeader: false)
    }

    var body: some View {
        Group {
            if showsPage {
                pageAndPanel
            } else {
                // No page here, so the panel is the region: the shelf's inspector is one
                // column of Info, Rename, Notes and Cite, not a panel clinging to the
                // side of a PDF nobody opened.
                panelColumn
            }
        }
        .onAppear { if draft.isEmpty { draft = item.destinationName } }
        .onChange(of: item.key) { _, _ in
            editing = false
            addingNote = false
            noteText = ""
        }
    }

    /// The page and the panel beside it, rather than stacked. The panel was a drawer
    /// under the page capped at 300 points, which is why the notes needed a column of
    /// their own to be readable at all -- and that column was 240 fixed points the
    /// window's minimum width had to reserve for whether or not anyone opened it.
    private var pageAndPanel: some View {
        HStack(spacing: 0) {
            // Wide: the page and the panel side by side. Narrow: the panel keeps its
            // floor and the page folds away, which costs no horizontal room -- ⏎ opens
            // the reader, where the page has the whole region to itself.
            if pageFits {
                pageRegion
                if showsPanel { Divider() }
            }
            if showsPanel {
                panelColumn.frame(width: SplitLayout.panelWidth(paneWidth: paneWidth))
            }
        }
    }

    /// Whether there is room for the page beside the panel. The panel does not shrink
    /// below `SplitLayout.panelFloor`: asked to, its controls overflow the frame they
    /// were given and paint over whatever is beside them.
    private var pageFits: Bool {
        !showsPanel || SplitLayout.showsPageBesidePanel(paneWidth: paneWidth)
    }

    /// The page, with the outline beside it where the window is wide enough to hold both.
    private var pageRegion: some View {
        // The contents rail's width is read off the room the page actually got, so
        // on a window too narrow for both it is the chapter list that narrows and
        // not the page that is squeezed to nothing, or worse, pushed off the edge.
        GeometryReader { page in
            HStack(spacing: 0) {
                if prefs.contentsShown && hasContents && !contentsIsPopover {
                    ContentsRail(annotator: annotator)
                        .frame(width: SplitLayout.contentsRailWidth(
                            inspectorWidth: page.size.width))
                        .region(.contents)
                    Divider()
                }
                PDFPreview(url: item.currentURL, passwords: passwords,
                           annotator: annotator, fit: prefs.pageFit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The page is an AppKit view hosted in SwiftUI, and a hosted view does
                // not honour the frame it was given while it is being resized: squeezed
                // narrow, it kept drawing at its old width, straight over the panel
                // beside it. Clipping is what actually holds it to its pane.
                .clipped()
                .overlay { nightTint }
                .overlay(alignment: .topTrailing) { lockedOverlay }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): pointer(at: point)
                    case .ended: hideMarkBar(after: .milliseconds(350))
                    }
                }
                .overlay(alignment: .topLeading) { floatingSelectionBar }
                .overlay(alignment: .topLeading) { floatingMarkBar }
                .overlay(alignment: .bottom) {
                    PageBar(annotator: annotator, fit: $prefs.pageFit)
                        .padding(.bottom, Space.roomy)
                }
            }
            .clipped()
        }
    }

    private var panelColumn: some View {
        panelStack
            // A frame is not a clip in SwiftUI: without this a panel narrower than its
            // own controls draws straight over the page beside it.
            .clipped()
            // Opaque on purpose: this sits against a page, and a panel of controls with
            // paragraphs showing through it is unreadable in both directions.
            .background(Color(nsColor: .windowBackgroundColor))
            .region(.inspector)
    }

    private var panelStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
            // Notes are not padded and not scrolled here. They are a list with a bar of
            // their own at the top and another at the bottom, and inside this scroll view
            // both bars scrolled away with the marks -- the export bar sat below the fold
            // of a pane it was supposed to be pinned to.
            if prefs.inspectorPanel == .notes {
                notesPanel
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.step) {
                        switch prefs.inspectorPanel {
                        case .rename: renamePanel
                        case .details:
                            MetadataPanel(item: item, excerpt: excerpt, tags: tags, read: read,
                                          livePage: showsPage ? annotator.page : nil,
                                          livePageCount: showsPage ? annotator.pageCount : nil)
                        case .bibtex: bibtexPanel
                        case .notes: EmptyView()
                        }
                    }
                    .padding(Space.roomy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Pinned, like the notes tab's export bar. A reviewer presses one of these
                // on every file; they should not be below however much this particular
                // document had to say about itself.
                if prefs.inspectorPanel == .rename {
                    Divider()
                    renameActions
                }
                if prefs.inspectorPanel == .details {
                    Divider()
                    infoActions
                }
            }
        }
    }

    /// Reading in the dark: the page tinted rather than inverted.
    ///
    /// Inverting a scanned plate or a figure turns it into a negative, which is worse than
    /// a bright page. Multiplying a warm dark colour over the page dims the paper and
    /// leaves the ink and the artwork where they were, and it takes the highlights down
    /// with it so they tint the paper instead of glowing off it.
    @ViewBuilder
    private var nightTint: some View {
        if prefs.readingTint && isDark {
            Color(red: 0.42, green: 0.40, blue: 0.36)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }

    private var panelHeader: some View {
        header
    }

    /// Four tabs, and the way back out of the reader. Nothing else.
    ///
    /// It used to carry a status pill, the contents toggle, Reveal, Open, a notes button
    /// and a collapse chevron beside them, which on a 320-point panel left the four tabs
    /// squeezed to about half the row. Every one of those has a key and a home elsewhere:
    /// the contents rail and the panel itself are toolbar buttons, Reveal and Open are
    /// ⌘R and O, and Notes is one of the tabs.
    private var header: some View {
        HStack(spacing: Space.step) {
            if let leaveReader {
                Button(action: leaveReader) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .tip("Back to the shelf", key: "⎋")
            }

            // Drawn while reading too. The panel is only here at all if it was asked for,
            // and a panel you can open on a tab you cannot leave is a dead end.
            Picker("", selection: $prefs.inspectorPanel) {
                ForEach(InspectorPanel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(prefs.inspectorCollapsed)
            .tip("Rename this file, read what it says about itself, or take its citation")
        }
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The marking bar, placed against the selection rather than parked at an edge.
    ///
    /// It sits above the selected lines where there is room and below them otherwise, and
    /// is kept inside the pane so it cannot end up half off the side.
    @ViewBuilder
    private var floatingSelectionBar: some View {
        if annotator.hasSelection {
            GeometryReader { geometry in
                // Wider when the ChatGPT menu is in it: the bar's width is fixed, so a
                // new target has to be paid for rather than squeezed out of the swatches.
                let handoff = ChatGPTHandoff.isInstalled && (prefs.offerChatGPT || prefs.offerChatGPTCopy)
                // Measured from the palette, for the same reason the mark bar's is: these
                // were 250 and 284, written when the palette had five colours in it, and
                // the palette is a list the reader edits.
                let bar = CGSize(width: CGFloat(palette.styles.count) * 27 + (handoff ? 106 : 72),
                                 height: 40)
                let box = annotator.selectionRect ?? CGRect(
                    x: geometry.size.width / 2, y: geometry.size.height - 60, width: 0, height: 0)
                let above = box.minY - bar.height - 8
                let y = above > 8 ? above : min(box.maxY + 8, geometry.size.height - bar.height - 8)
                let x = min(max(box.midX - bar.width / 2, 8), max(8, geometry.size.width - bar.width - 8))

                selectionBar
                    .fixedSize()
                    .offset(x: x, y: y)
                    .animation(.easeOut(duration: 0.12), value: box)
            }
            .transition(.opacity)
        }
    }

    /// The mark under the pointer, read fresh out of the annotator each time.
    private var hoveredMark: Annotator.Mark? {
        guard let hoveredMarkID else { return nil }
        return annotator.marks.first { $0.id == hoveredMarkID }
    }

    private func pointer(at point: CGPoint) {
        guard !annotator.hasSelection else { return }
        if let mark = annotator.mark(atViewPoint: point) {
            markBarHide?.cancel()
            markBarHide = nil
            if hoveredMarkID != mark.id { hoveredMarkID = mark.id }
        } else {
            hideMarkBar(after: .milliseconds(350))
        }
    }

    private func hideMarkBar(after delay: Duration) {
        guard hoveredMarkID != nil, markBarHide == nil else { return }
        markBarHide = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            hoveredMarkID = nil
            markBarHide = nil
        }
    }

    /// The same bar a fresh selection gets, over a mark that already exists.
    ///
    /// A highlight you have already made was a thing you could only act on from the notes
    /// rail: to change its colour you had to find its row. It is the same three questions
    /// either way -- what colour, what note, and whether to keep it -- so it is the same
    /// bar, in the same place, against the thing it is about.
    @ViewBuilder
    private var floatingMarkBar: some View {
        if !annotator.hasSelection, let mark = hoveredMark, let box = annotator.rect(of: mark) {
            GeometryReader { geometry in
                // Measured from the palette rather than fixed. A swatch and its gap are
                // 27 points, the divider and the two buttons about 60, and the capsule's
                // own padding 24; a fixed number is a bar that is centred correctly only
                // for whichever palette size it was written for, and this one is a list
                // the reader edits.
                // An estimate, used to centre the bar over the mark and to keep it
                // inside the pane. The bar takes its own width -- `.frame(width:)`
                // squeezed the content into a number written for a five-colour palette,
                // and a reader who had added two more got a trash can cut in half by the
                // capsule's edge.
                let bar = CGSize(width: CGFloat(palette.styles.count) * 27 + 96, height: 40)
                let above = box.minY - bar.height - 8
                let y = above > 8 ? above : min(box.maxY + 8, geometry.size.height - bar.height - 8)
                let x = min(max(box.midX - bar.width / 2, 8), max(8, geometry.size.width - bar.width - 8))

                markBar(mark)
                    .fixedSize()
                    .offset(x: x, y: y)
                    .animation(.easeOut(duration: 0.12), value: box)
                    // Hovering the bar counts as still being on the mark, or it would
                    // vanish on the way to it.
                    .onHover { inside in
                        if inside {
                            markBarHide?.cancel()
                            markBarHide = nil
                        } else {
                            hideMarkBar(after: .milliseconds(350))
                        }
                    }
            }
            .transition(.opacity)
        }
    }

    private func markBar(_ mark: Annotator.Mark) -> some View {
        let current = palette.nearest(to: mark.colour)
        return HStack(spacing: Space.step) {
            ForEach(palette.styles) { style in
                Button { annotator.setColour(style.nsColor, on: mark) } label: {
                    Circle()
                        .fill(style.swatch)
                        .frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(.primary.opacity(
                            style.id == (hovered ?? current?.id) ? 0.6 : 0.15), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? style.id : nil }
                .accessibilityLabel(style.meaning.isEmpty ? "Unnamed colour" : style.meaning)
            }

            Divider().frame(height: 16)

            Button {
                annotator.selectedMark = mark.id
                prefs.inspectorPanel = .notes
                prefs.inspectorCollapsed = false
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mark.note.isEmpty ? "Write a note" : "Read the note")
            .tip(mark.note.isEmpty ? "Write a note on this mark" : "Show this mark's note")

            Button { annotator.remove(mark) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this mark")
            .tip("Remove this mark from the file")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.snug)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }

    private var selectionBar: some View {
        HStack(spacing: Space.step) {
            ForEach(palette.styles) { style in
                Button {
                    annotator.highlightSelection(colour: style.nsColor)
                    prefs.lastHighlightColour = style.id.uuidString
                    prefs.inspectorPanel = .notes
                    prefs.inspectorCollapsed = false
                } label: {
                    Circle()
                        .fill(style.swatch)
                        .frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(.primary.opacity(
                            style.id == (hovered ?? lastStyle?.id) ? 0.6 : 0.15), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                // Named in the bar itself rather than left to the system tooltip, which
                // waits a second or two: too slow for a palette whose whole point is
                // knowing what a colour stands for.
                .onHover { hovered = $0 ? style.id : nil }
            }

            Divider().frame(height: 16)

            Button {
                prefs.inspectorPanel = .notes
                prefs.inspectorCollapsed = false
                addingNote = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Write a note")
            .onHover { hoveringNote = $0 }

            // One menu, not two more bare icons: the bar is a fixed width and already
            // carries the swatches, a divider and the note button. Hover is reported into
            // the same immediate label the rest of the bar uses, since `.help` waits a
            // second or two before saying anything.
            if ChatGPTHandoff.isInstalled && (prefs.offerChatGPT || prefs.offerChatGPTCopy) {
                Menu {
                    if prefs.offerChatGPT {
                        Button("Open in ChatGPT") { handOffSelection(copyOnly: false) }
                    }
                    if prefs.offerChatGPTCopy {
                        Button("Copy for ChatGPT") { handOffSelection(copyOnly: true) }
                    }
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hoveringChatGPT = $0 }
                .accessibilityLabel("Send the selected passage to ChatGPT")
            }
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.snug)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metric.card))
        .overlay(alignment: .top) { meaningLabel }
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }

    /// Hands whatever is selected right now to ChatGPT. Read at the moment the button is
    /// pressed rather than held in state, so a selection changed while the menu was open
    /// cannot send the passage the reader was looking at a moment ago.
    private func handOffSelection(copyOnly: Bool) {
        guard let selection = annotator.selectionForHandoff() else { return }
        let prompt = ChatGPTHandoff.prompt(quoted: selection.quoted, note: "",
                                           page: selection.page, title: selection.title)
        if copyOnly {
            ChatGPTHandoff.copy(prompt)
        } else {
            ChatGPTHandoff.open(prompt)
        }
    }

    /// What the colour under the pointer means, shown immediately above the bar.
    @ViewBuilder
    private var meaningLabel: some View {
        if let text = hoveredMeaning
            ?? (hoveringNote ? "Highlight and attach a note" : nil)
            ?? (hoveringChatGPT ? "Ask ChatGPT about this passage" : nil) {
            Text(text)
                .font(Face.caption)
                .lineLimit(1)
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.tight)
                .fittedBackground(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .offset(y: -24)
                .transition(.opacity)
        }
    }

    /// What Return in the name field does. Applying the rename there and then is what
    /// most of this app's editing is for, and it makes the button beside the field a
    /// second way to do the same thing rather than the only way. Someone building a plan
    /// to apply in one go wants the other behaviour, so it is a setting.
    private func submit() {
        if prefs.returnAppliesRename {
            applyNow()
        } else {
            confirm()
        }
    }

    @ViewBuilder
    /// The name, where it came from, what the document says, and what you can do about
    /// it -- in that order, because that is the order the question is answered in.
    ///
    /// It was a field, a "was" line and eleven buttons in two wrapping rows. The buttons
    /// were the loudest thing in the panel and the reasoning behind the name was not in it
    /// at all, so agreeing with a name meant taking it on trust.
    private var renamePanel: some View {
        VStack(alignment: .leading, spacing: Space.gutter) {
            newNameSection
            builtFromSection
            readFromDocumentSection

            // Ask AI only. Copying a citation is what the Cite tab is for, and its own
            // Copy button carries the same B; a second one here made the rename panel
            // answer a question it was not being asked. The shortcut still works.
            HStack(spacing: Space.step) {
                Button(action: identify) { KeyLabel("G", "Ask AI") }
                    .disabled(!aiReady || runner.ai.isThinking(item))
                    .tip(aiReady ? "Read the opening pages and suggest a title"
                                 : "Add an API key in Settings first", key: "G")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A section heading: what the block under it is, in the smallest type that still
    /// reads, so the blocks are told apart without a rule between them.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Face.caption.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }

    private var newNameSection: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            sectionLabel("NEW NAME")
            TextField("Name", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(Face.mono)
                .lineLimit(1...3)
                .focused($editing)
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    leaveField()
                    return .handled
                }
                .strikethrough(decision == .deleted)

            HStack(spacing: Space.snug) {
                if isEdited {
                    Text("edited").foregroundStyle(Ink.blue)
                    Button("Reset", action: reset).buttonStyle(.link)
                    Spacer(minLength: 0)
                } else {
                    KeyLabel("E", "to edit")
                    Text("\u{00B7}")
                    KeyLabel("\u{2318}Z", "to undo the last decision")
                    Spacer(minLength: 0)
                }
            }
            .font(Face.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if !item.message.isEmpty {
                Text(item.message)
                    .font(Face.caption)
                    .foregroundStyle(item.status == .failed ? Ink.red : Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The ingredients, and the one or two things worth saying about how they were found.
    /// Both come from `nameProvenance`, which claims nothing it cannot point at.
    @ViewBuilder
    private var builtFromSection: some View {
        let provenance = nameProvenance(for: item, guess: runner.ai.guesses[item.key])
        if !provenance.isEmpty {
            VStack(alignment: .leading, spacing: Space.step) {
                sectionLabel("BUILT FROM")
                FlowLayout(spacing: Space.snug) {
                    ForEach(provenance.parts, id: \.value) { part in
                        HStack(spacing: Space.tight) {
                            Text(part.label).foregroundStyle(.secondary)
                            // A title can be the whole name. Held to the panel's width
                            // and truncated in the middle, since both ends of a slug are
                            // what identify it; the field above carries the whole thing.
                            Text(part.value)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(Face.caption)
                        .frame(maxWidth: 230, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.step)
                        .padding(.vertical, Space.tight)
                        .background(.quaternary.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: Metric.control))
                    }
                }
                if !provenance.notes.isEmpty {
                    Text(provenance.notes.joined(separator: " "))
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What the file itself says, as against what the plan made of it. Four lines: enough
    /// to tell whether the name above is right, and no more -- the rest is the Info tab.
    @ViewBuilder
    private var readFromDocumentSection: some View {
        let rows = documentRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.step) {
                sectionLabel("READ FROM THE DOCUMENT")
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(rows, id: \.0) { row in
                        HStack(alignment: .firstTextBaseline, spacing: Space.step) {
                            Text(row.0)
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(row.1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Face.caption)
                    }
                }
            }
        }
    }

    /// Only what the document actually said. A row of "unknown" four times over says
    /// nothing except that the file is a scan, which the page already shows.
    private var documentRows: [(String, String)] {
        var rows: [(String, String)] = []
        let guess = runner.ai.guesses[item.key]
        if let title = stated(item.documentInfo["Title"]) ?? guess?.title {
            rows.append(("Title", title))
        }
        if let author = stated(item.documentInfo["Author"]) ?? guess?.author {
            rows.append(("Author", author))
        }
        if let year = guess?.year ?? item.metadataDate.map({ ReviewInspector.year.string(from: $0) }) {
            rows.append(("Year", year))
        }
        if let pages = item.pageCount {
            let lock: String
            switch item.status {
            case .decrypted: lock = " \u{00B7} unlocked with a password you gave"
            case .locked: lock = " \u{00B7} locked, no password matched"
            case .encrypted: lock = " \u{00B7} will be written out locked"
            default: lock = ""
            }
            rows.append(("Pages", "\(pages)\(lock)"))
        }
        return rows
    }

    /// A year on its own, for the one row that wants one.
    private static let year: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private func stated(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What can be done with the file, pinned under what it says about itself, in the
    /// same place the Rename tab keeps its decision.
    ///
    /// "Read" is not offered while you are already reading: a button that opens what is
    /// open is a button that does nothing, and it was the loudest thing on the tab.
    private var infoActions: some View {
        VStack(spacing: Space.step) {
            if leaveReader == nil {
                Button(action: read) {
                    Label("Read", systemImage: "book").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tip("Open the page, its outline and your marks on it", key: "⏎")
            }
            HStack(spacing: Space.step) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.currentURL])
                }
                .frame(maxWidth: .infinity)
                .tip("Show this file in the Finder", key: "⌘R")
                Button("Quick Look") { QuickLook.show(item.currentURL) }
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
        .background(.bar)
    }

    /// The decision, pinned under the panel rather than scrolled with it.
    ///
    /// A reviewer presses one of these on every file, so they belong where the pointer
    /// already is instead of below however much the document had to say about itself.
    private var renameActions: some View {
        VStack(spacing: Space.step) {
            if decision == nil {
                Button(action: confirm) {
                    HStack(spacing: Space.snug) {
                        Text("Confirm and continue")
                        Text("\u{21A9}")
                            .font(Face.mono.weight(.bold))
                            .padding(.horizontal, Space.tight)
                            .background(.white.opacity(0.22),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: reopen) {
                    KeyLabel("R", decidedLabel).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tip("Undo this decision and look at the file again", key: "R")
            }

            HStack(spacing: Space.step) {
                Button(action: skip) { KeyLabel("S", "Skip") }
                    .tip("Leave this file exactly as it is", key: "S")
                Button(action: skipFolder) { KeyLabel("F", "Folder") }
                    .disabled(pendingInFolder == 0)
                    .tip("Skip the rest of \(folderName)", key: "F")
                Button(action: moveTo) { KeyLabel("M", "Move") }
                    .tint(Ink.purple)
                Button(action: markDeleted) { KeyLabel("D", "Trash") }
                    .tint(Ink.red)
                    .tip("To the Trash on apply, recoverable", key: "D")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.step)
        .background(.bar)
    }

    /// What the row was decided, for the button that takes it back.
    private var decidedLabel: String {
        switch decision {
        case .confirmed: return "Confirmed \u{2014} reopen"
        case .applied: return "Applied \u{2014} reopen"
        case .skipped: return "Skipped \u{2014} reopen"
        case .deleted: return "Going to the Trash \u{2014} reopen"
        case .moveTo(let folder): return "Moving to \(folder.lastPathComponent) \u{2014} reopen"
        case nil: return "Reopen"
        }
    }

    @ViewBuilder
    private var lockedOverlay: some View {
        if item.status == .locked {
            Label("No password matched, cannot be shown", systemImage: "lock.fill")
                .font(Face.caption.weight(.medium))
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.tight)
                .fittedBackground(.regularMaterial, in: Capsule())
                .padding(Space.step)
        }
    }

}

/// A button label that carries its own shortcut, so the keys are discoverable without a
/// legend somewhere else in the window.
struct KeyLabel: View {
    let key: String
    let title: String

    init(_ key: String, _ title: String) {
        self.key = key
        self.title = title
    }

    var body: some View {
        HStack(spacing: Space.tight) {
            Text(key)
                .font(Face.mono.weight(.bold))
                .frame(minWidth: 14, minHeight: 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(title)
        }
    }
}

/// A `PDFView` that fits the page to the pane's width and starts at the top of the
/// document, rather than shrinking the whole page to fit and centring it.
/// How big the page is drawn. Named rather than a scale factor because these are the
/// three answers a reader actually wants, and only one of them is a number.
enum PageFit: String, CaseIterable, Identifiable {
    case width, page, actual
    var id: String { rawValue }

    var label: String {
        switch self {
        case .width: return "Fit width"
        case .page: return "Fit page"
        case .actual: return "Actual size"
        }
    }
}

final class FitWidthPDFView: PDFView {
    private var wantsTopScroll = false

    /// How the page is sized in the room it has. Fitting the width is what a page of text
    /// wants; the other two are here because a figure and a scan do not.
    var fit: PageFit = .width {
        didSet { if fit != oldValue { needsLayout = true } }
    }

    /// The gap between the page and the pane around it. A page drawn edge to edge reads
    /// as the window's background rather than as a sheet of paper, which is what the
    /// shadow and this margin together are for.
    static let margin: CGFloat = 28

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        fitToWidth()
    }

    func showFromTop() {
        wantsTopScroll = true
        needsLayout = true
    }

    /// PDFView keeps its own scroll view, whose content width already excludes a legacy
    /// scroller. Measuring that instead of `bounds` stops the fit from oscillating by a
    /// scroller's width on every layout pass.
    private var availableWidth: CGFloat {
        let inner = subviews.compactMap { $0 as? NSScrollView }.first
        return inner.map { $0.contentSize.width } ?? bounds.width
    }

    private func fitToWidth() {
        guard let page = document?.page(at: 0) else { return }
        let box = page.bounds(for: displayBox)
        let width = availableWidth
        guard box.width > 0, width > 0 else { return }

        let room = max(1, width - 2 * FitWidthPDFView.margin)
        let wanted: CGFloat
        switch fit {
        case .width: wanted = room / box.width
        case .page:
            let height = max(1, bounds.height - 2 * FitWidthPDFView.margin)
            wanted = box.height > 0 ? min(room / box.width, height / box.height) : room / box.width
        case .actual: wanted = 1
        }
        let target = min(max(wanted, minScaleFactor), maxScaleFactor)
        if abs(scaleFactor - target) > 0.002 { scaleFactor = target }

        if wantsTopScroll {
            wantsTopScroll = false
            let top = CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)
            go(to: PDFDestination(page: page, at: top))
        }
    }
}

/// Renders the PDF as it is right now, unlocking it for display with the same passwords
/// the run would use. Read-only: the file on disk is untouched.
struct PDFPreview: NSViewRepresentable {
    let url: URL
    let passwords: [String]
    var annotator: Annotator?
    var fit: PageFit = .width
    /// Open at this page, one-based. For a citation, which is about one page rather than
    /// about the document: opening its book at the front and leaving you to find p. 108
    /// is most of the work the citation was supposed to save.
    var page: Int?

    func makeCoordinator() -> Coordinator { Coordinator(annotator: annotator) }

    func makeNSView(context: Context) -> FitWidthPDFView {
        let view = FitWidthPDFView()
        // An NSView does not clip its content to its own bounds, so a PDF squeezed by the
        // pane beside it went on drawing at the width it had a moment ago -- straight over
        // the inspector. SwiftUI's own `.clipped()` cannot fix that: the page is a real
        // AppKit view, not something SwiftUI rasterises.
        view.clipsToBounds = true
        // autoScales fits the whole page and centres it, which is the opposite of what a
        // page of text wants.
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // A sheet of paper on a desk, rather than ink printed on the window. The shadow
        // and the margin are what say where the page ends, which matters most on a scan
        // whose own paper is off-white and on a figure that runs to the trim.
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: FitWidthPDFView.margin,
                                             left: FitWidthPDFView.margin,
                                             bottom: FitWidthPDFView.margin,
                                             right: FitWidthPDFView.margin)
        // Not `.underPageBackgroundColor`, which is very nearly white: against it a page
        // has no edge, and the shadow has nothing to fall on.
        view.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? srgb(28, 28, 30) : srgb(232, 232, 235)
        }
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged, object: view
        )
        return view
    }

    func updateNSView(_ view: FitWidthPDFView, context: Context) {
        // What the view is showing is not the whole answer any more: a load can be in
        // flight, and SwiftUI calls this again for reasons that have nothing to do with
        // the file. The coordinator remembers what was asked for, so the same file is
        // never read twice over and A -> B -> A does not end up showing B.
        let coordinator = context.coordinator
        // Set before the early return: the fit changes far more often than the file, and
        // reading a different document is not what a zoom menu is asking for.
        view.fit = fit
        if coordinator.wanted == url, let page, coordinator.shown != page {
            coordinator.shown = page
            go(view, to: page)
        }
        guard coordinator.wanted != url else { return }

        // Parsing a document is not free: a two-hundred-page thesis takes the better part
        // of a tenth of a second, and doing it here held the main thread for exactly that
        // long on every move through the list. It is read off the main thread instead, and
        // a load that lands after the selection has moved on is dropped rather than drawn
        // over the file now selected.
        let wanted = url
        coordinator.wanted = wanted
        let passwords = passwords
        let annotator = annotator

        Task { @MainActor in
            let loaded = await PDFPreview.load(url: wanted, passwords: passwords)
            guard coordinator.wanted == wanted else { return }
            guard let document = loaded.document else {
                // Nothing to show and nothing to remember: a later pass should be free to
                // try this file again rather than treat it as already handled.
                coordinator.wanted = nil
                return
            }
            view.document = document
            // After the document, not before it: PDFView drops the setting when a
            // document is assigned, which is why the page had a margin and no shadow.
            view.pageShadowsEnabled = true
            if let page {
                coordinator.shown = page
                go(view, to: page)
            } else {
                view.showFromTop()
            }
            annotator?.attach(view, url: wanted)
            // The reader's local key monitor deliberately lets arrows continue down the
            // responder chain. Make the PDF canvas that responder so scrolling and text
            // selection work from the keyboard without first clicking the page.
            view.window?.makeFirstResponder(view)
        }
    }

    /// Turns to a page, one-based and clamped, at the top of it.
    private func go(_ view: PDFView, to number: Int) {
        guard let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(max(number, 1), document.pageCount) - 1)
        else { return }
        view.go(to: PDFDestination(page: page,
                                   at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
    }

    /// Carries a document back from the thread that parsed it. `PDFDocument` is not
    /// `Sendable`, and nothing else touches this one until the hop is done.
    private struct Loaded: @unchecked Sendable {
        let document: PDFDocument?
    }

    private static func load(url: URL, passwords: [String]) async -> Loaded {
        await Task.detached(priority: .userInitiated) {
            let document = PDFDocument(url: url)
            if document?.isLocked == true {
                for password in passwords where document?.unlock(withPassword: password) == true {
                    break
                }
            }
            return Loaded(document: document)
        }.value
    }

    final class Coordinator: NSObject {
        let annotator: Annotator?
        /// The file the view should end up showing, so a slower load of the file before it
        /// can tell that it is no longer wanted.
        @MainActor var wanted: URL?
        /// The page it was last turned to, so asking for the same one twice does not
        /// scroll it back there while somebody is reading around it.
        @MainActor var shown: Int?
        init(annotator: Annotator?) { self.annotator = annotator }

        @objc func selectionChanged() {
            Task { @MainActor in annotator?.selectionChanged() }
        }
    }
}

/// Which panel the inspector's bottom pane shows.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case details, rename, notes, bibtex
    var id: String { rawValue }

    var label: String {
        switch self {
        case .details: return "Info"
        case .rename: return "Rename"
        case .notes: return "Notes"
        case .bibtex: return "Cite"
        }
    }
}

/// What the file says about itself, under the actions that act on it.
///
/// Only what exists is shown. A grid of mostly-empty rows would push the useful line off
/// the bottom, and an absent field is not worth a row saying so.
struct MetadataPanel: View {
    let item: Item
    let excerpt: String?
    /// Tagging where the file is actually being looked at. It was reachable only by
    /// right-clicking a row, which is not somewhere anyone looks for it.
    var tags: TagActions = .none
    /// Opens this document in the reader. The shelf shows no page, so this is the way in.
    var read: (() -> Void)?

    /// How far in the reader got last time, read from the library rather than from the
    /// page, since the shelf has no page open.
    @State private var position: ReadingPosition?
    var livePage: Int? = nil
    var livePageCount: Int? = nil
    /// Which reading projects this document is filed under.
    @State private var projects: [String] = []

    var body: some View {
        panel.task(id: item.key) { await loadPosition() }
    }

    private func loadPosition() async {
        position = nil
        projects = []
        guard let library = Library.shared else { return }
        let path = item.currentURL.resolvingSymlinksInPath().path
        guard let record = try? await library.document(atPath: path) else { return }
        position = try? await library.readingPosition(forDocument: record.id)
        projects = ((try? await library.projects(containingDocument: record.id)) ?? [])
            .map(\.name)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            heading
            group("File", rows: fileRows)
            suggested
            group("Reading", rows: readingRows)
            opening
        }
        .padding(.top, Space.hair)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the book calls itself, in its own voice, with the tags under it.
    private var heading: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(title)
                .font(Face.page)
                .fontWeight(.semibold)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let author = item.documentInfo["Author"], !author.isEmpty {
                Text(author)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TagStrip(actions: tags)
        }
    }

    private var title: String {
        let stated = item.documentInfo["Title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stated, !stated.isEmpty { return stated }
        return (item.destinationName as NSString).deletingPathExtension
    }

    /// One labelled group, drawn only when it has something to say. An absent field is
    /// not worth a row saying so.
    @ViewBuilder
    private func group(_ label: String, rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(label)
                    .font(Face.section)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(rows, id: \.0) { name, value in
                        GridRow {
                            Text(name)
                                .font(Face.caption)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(value)
                                .font(Face.caption)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var fileRows: [(String, String)] {
        var rows: [(String, String)] = [("Name", item.currentURL.lastPathComponent)]
        let folder = (item.relativePath as NSString).deletingLastPathComponent
        rows.append(("Where", folder.isEmpty
                     ? item.root.lastPathComponent
                     : item.root.lastPathComponent + " / " + folder.replacingOccurrences(of: "/", with: " / ")))
        let size = [
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            item.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" },
        ].compactMap { $0 }.joined(separator: " · ")
        if !size.isEmpty { rows.append(("Size", size)) }
        if let modified = item.modifiedDate {
            rows.append(("Added", modified.formatted(date: .abbreviated, time: .omitted)))
        }
        rows.append(("Status", item.status.rawValue.capitalized))
        return rows
    }

    /// The rename this file is part of, and why it came out that way. Only for a file the
    /// plan actually changes: a row saying a name is unchanged is a row about nothing.
    @ViewBuilder
    private var suggested: some View {
        if item.destinationName != item.sourceName {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Suggested name")
                    .font(Face.section)
                    .foregroundStyle(.secondary)
                Text(item.sourceName)
                    .font(Face.mono)
                    .foregroundStyle(.secondary)
                    .strikethrough()
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(item.destinationName)
                    .font(Face.mono)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !item.message.isEmpty {
                    Text(item.message)
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var readingRows: [(String, String)] {
        var rows: [(String, String)] = []
        // While the page is visible, the PDF view is the source of truth. The library
        // position is intentionally debounced, so reading it here made the inspector
        // lag behind the page by up to a second.
        if let livePage, let livePageCount, livePage > 1, livePage < livePageCount {
            let percent = (livePage - 1) * 100 / (livePageCount - 1)
            rows.append(("Progress", "page \(livePage) of \(livePageCount) · \(percent)%"))
        } else if let position, position.isInProgress {
            let percent = position.fraction.map { " · \(Int($0 * 100))%" } ?? ""
            let total = position.pageCount.map { " of \($0)" } ?? ""
            rows.append(("Progress", "page \(position.page)\(total)\(percent)"))
        }
        if !projects.isEmpty {
            rows.append(("Projects", projects.joined(separator: ", ")))
        }
        return rows
    }

    /// The first words of the document, or the reason there are none.
    @ViewBuilder
    private var opening: some View {
        if let excerpt, !excerpt.isEmpty {
            Text(excerpt)
                .font(Face.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Metric.control))
                // Keep stale/oversized text from painting over the actions below it.
                // `lineLimit` controls layout, but hosted inspector content still needs a
                // hard visual bound when SwiftUI receives a very long PDF text layer.
                .frame(maxHeight: 88, alignment: .top)
                .clipped()
        } else if item.status == .locked {
            Label("Locked, so nothing inside can be read", systemImage: "lock.fill")
                .font(Face.caption)
                .foregroundStyle(.secondary)
        }
    }

}

// MARK: - Status
