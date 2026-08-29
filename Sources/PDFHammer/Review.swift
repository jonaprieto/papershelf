import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

struct ReviewInspector: View {
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
    @ObservedObject var runner: Runner
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
    @Binding var autoIdentify: Bool
    let reveal: () -> Void
    let openExternally: () -> Void
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
    let reading: Bool

    /// This file's tags, so the Details panel can show and change them.
    var tags: TagActions = .none

    @ObservedObject var annotator: Annotator
    @ObservedObject var palette: Palette
    @AppStorage("inspectorPanel") private var panel: InspectorPanel = .rename

    // The bibliography entry for this one file, edited in place. See BibtexPanel.swift.
    /// The same preference the bibliography tab uses, so one entry is never judged by a
    /// different standard from the file it will end up in.
    @AppStorage("bibStandard") var bibStandard: BibStandard = .biblatex

    @State var citationDraft = ""
    @State var citationStored = false
    @State var citationImproving = false
    @State var citationImprovedByAI = false
    @State var citationNote: String?
    @AppStorage("inspectorCollapsed") private var collapsed = false
    /// The inspector is on its Notes tab and open. What used to be a rail with a switch
    /// of its own is a tab, so "are the notes showing" is a question about the inspector.
    private var showingNotes: Bool { panel == .notes && !collapsed }
    @AppStorage("contentsShown") private var contentsShown = false
    @AppStorage("readingTint") private var readingTint = true
    @AppStorage("offerChatGPT") private var offerChatGPT = true
    @AppStorage("offerChatGPTCopy") private var offerChatGPTCopy = true
    @Environment(\.colorScheme) private var colourScheme
    private var isDark: Bool { colourScheme == .dark }
    @State private var addingNote = false
    @State private var noteText = ""
    @AppStorage("lastHighlightColour") private var lastColourID = ""
    @State private var hovered: UUID?
    @State private var hoveringNote = false
    @State private var hoveringChatGPT = false

    private var lastStyle: HighlightStyle? {
        palette.styles.first { $0.id.uuidString == lastColourID } ?? palette.styles.first
    }

    private var hoveredMeaning: String? {
        guard let hovered, let style = palette.styles.first(where: { $0.id == hovered })
        else { return nil }
        return style.meaning.isEmpty ? "Unnamed highlighter" : style.meaning
    }

    /// While reading, the deciding controls stay out of the way.
    private var showBottom: Bool { !collapsed && !reading }

    /// Below `SplitLayout.inspectorOverlaysBelow` the panel is drawn over the page rather
    /// than beside it. Nothing is lost at a narrow width; it stops costing the page room
    /// it does not have, which is what lets the window reach 640 points.
    private var panelOverlays: Bool { SplitLayout.inspectorOverlays(paneWidth: paneWidth) }

    /// Below `SplitLayout.contentsFoldsBelow` the outline is a popover under its own
    /// toolbar button instead of a third column.
    private var contentsIsPopover: Bool { SplitLayout.contentsIsPopover(paneWidth: paneWidth) }

    private var hasContents: Bool { !annotator.contents.isEmpty }

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
                if showBottom { Divider() }
            }
            if showBottom {
                panelColumn.frame(width: SplitLayout.panelWidth(paneWidth: paneWidth))
            }
        }
    }

    /// Whether there is room for the page beside the panel. The panel does not shrink
    /// below `SplitLayout.panelFloor`: asked to, its controls overflow the frame they
    /// were given and paint over whatever is beside them.
    private var pageFits: Bool {
        !showBottom || SplitLayout.showsPageBesidePanel(paneWidth: paneWidth)
    }

    /// The page, with the outline beside it where the window is wide enough to hold both.
    private var pageRegion: some View {
        // The contents rail's width is read off the room the page actually got, so
        // on a window too narrow for both it is the chapter list that narrows and
        // not the page that is squeezed to nothing, or worse, pushed off the edge.
        GeometryReader { page in
            HStack(spacing: 0) {
                if contentsShown && hasContents && !contentsIsPopover {
                    ContentsRail(annotator: annotator,
                                 close: { contentsShown = false })
                        .frame(width: SplitLayout.contentsRailWidth(
                            inspectorWidth: page.size.width))
                        .region(.contents)
                    Divider()
                }
                PDFPreview(url: item.currentURL, passwords: passwords, annotator: annotator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The page is an AppKit view hosted in SwiftUI, and a hosted view does
                // not honour the frame it was given while it is being resized: squeezed
                // narrow, it kept drawing at its old width, straight over the panel
                // beside it. Clipping is what actually holds it to its pane.
                .clipped()
                .background(.quaternary.opacity(0.35))
                .overlay { nightTint }
                .overlay(alignment: .topTrailing) { lockedOverlay }
                .overlay(alignment: .topLeading) { floatingSelectionBar }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch panel {
                    case .rename: renamePanel
                    case .details: MetadataPanel(item: item, excerpt: excerpt, tags: tags, read: read)
                    case .notes: notesPanel
                    case .bibtex: bibtexPanel
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        if readingTint && isDark {
            Color(red: 0.42, green: 0.40, blue: 0.36)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }

    private var panelHeader: some View {
        // Two versions, widest first: on a narrow inspector, one with the status pill in it
        // does not fit, and an HStack that does not fit does not tidy itself up -- it
        // overlaps its own controls and runs them past the edge. Dropping the pill is the
        // cheapest thing to lose, since the row it describes says the same thing.
        ViewThatFits(in: .horizontal) {
            header(showingStatus: true)
            header(showingStatus: false)
        }
    }

    private func header(showingStatus: Bool) -> some View {
        HStack(spacing: 8) {
            if let leaveReader {
                Button(action: leaveReader) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .tip("Back to the shelf", key: "⎋")
            }

            if showingStatus {
                StatusPill(status: item.status, count: nil)
            }

            if !reading {
                Picker("", selection: $panel) {
                    ForEach(InspectorPanel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(collapsed)
                .tip("Rename this file, read what it says about itself, or take its citation")
            }

            Spacer(minLength: 8)

            if hasContents && showsPage {
                Button {
                    contentsShown.toggle()
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(contentsShown ? Color.accentColor : .secondary)
                .tip(contentsShown ? "Hide the contents" : "Table of contents", key: "⌘⇧T")
                // Under `SplitLayout.contentsFoldsBelow` the outline has nowhere to stand
                // as a column, so it stands here instead: same button, same key, same
                // list, no horizontal room.
                .popover(isPresented: Binding(
                    get: { contentsShown && contentsIsPopover },
                    set: { contentsShown = $0 }
                ), arrowEdge: .bottom) {
                    ContentsRail(annotator: annotator, close: { contentsShown = false })
                        .frame(width: 300, height: 420)
                }
            }

            Button(action: reveal) { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .tip("Reveal in Finder", key: "⌘R")
            Button(action: openExternally) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .tip("Open in the default PDF viewer", key: "O")

            Button {
                if panel == .notes && !collapsed { collapsed = true } else { panel = .notes; collapsed = false }
            } label: {
                if reading {
                    Label(showingNotes ? "Hide notes" : "Notes",
                          systemImage: showingNotes ? "sidebar.trailing" : "note.text")
                } else {
                    Image(systemName: showingNotes ? "sidebar.trailing" : "note.text")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showingNotes ? Color.accentColor : .secondary)
            .help(showingNotes ? "Hide the notes (⌘⇧N)" : "Show notes and highlights (⌘⇧N)")
            .overlay(alignment: .topTrailing) {
                if !annotator.marks.isEmpty && !showingNotes {
                    Circle()
                        .fill(Ink.amber)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                }
            }

            if !reading {
                Button {
                    collapsed.toggle()
                } label: {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(collapsed ? "Show the panel" : "Hide the panel, give the room to the page")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
                let handoff = ChatGPTHandoff.isInstalled && (offerChatGPT || offerChatGPTCopy)
                let bar = CGSize(width: handoff ? 284 : 250, height: 40)
                let box = annotator.selectionRect ?? CGRect(
                    x: geometry.size.width / 2, y: geometry.size.height - 60, width: 0, height: 0)
                let above = box.minY - bar.height - 8
                let y = above > 8 ? above : min(box.maxY + 8, geometry.size.height - bar.height - 8)
                let x = min(max(box.midX - bar.width / 2, 8), max(8, geometry.size.width - bar.width - 8))

                selectionBar
                    .frame(width: bar.width, height: bar.height)
                    .offset(x: x, y: y)
                    .animation(.easeOut(duration: 0.12), value: box)
            }
            .transition(.opacity)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 7) {
            ForEach(palette.styles) { style in
                Button {
                    annotator.highlightSelection(colour: style.nsColor)
                    lastColourID = style.id.uuidString
                    panel = .notes
                    collapsed = false
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
                panel = .notes
                collapsed = false
                addingNote = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.plain)
            .onHover { hoveringNote = $0 }

            // One menu, not two more bare icons: the bar is a fixed width and already
            // carries the swatches, a divider and the note button. Hover is reported into
            // the same immediate label the rest of the bar uses, since `.help` waits a
            // second or two before saying anything.
            if ChatGPTHandoff.isInstalled && (offerChatGPT || offerChatGPTCopy) {
                Menu {
                    if offerChatGPT {
                        Button("Open in ChatGPT") { handOffSelection(copyOnly: false) }
                    }
                    if offerChatGPTCopy {
                        Button("Copy for ChatGPT") { handOffSelection(copyOnly: true) }
                    }
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hoveringChatGPT = $0 }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
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
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .fittedBackground(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .offset(y: -24)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var renamePanel: some View {
        Text(folderPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)

        VStack(alignment: .leading, spacing: 4) {
            Text("New name").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($editing)
                .onSubmit(confirm)
                .onKeyPress(.escape) {
                    leaveField()
                    return .handled
                }
                .strikethrough(decision == .deleted)
            HStack(spacing: 6) {
                Text("was \(item.sourceName)")
                if isEdited {
                    Text("edited")
                        .foregroundStyle(Ink.blue)
                    Button("Reset", action: reset).buttonStyle(.link)
                }
                Spacer(minLength: 0)
                decisionBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        if !item.message.isEmpty {
            Text(item.message)
                .font(.caption)
                .foregroundStyle(item.status == .failed ? Ink.red : Ink.amber)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        actionRows

        Text(decision == .deleted
             ? "Moves to the Trash on apply, so it stays recoverable. R puts it back."
             : "J or N next, K or P previous. ? lists every shortcut.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var actionRows: some View {
        // Wrapping, not scrolling sideways. In a 320-point column a horizontal scroll
        // view puts half the decisions off the edge with nothing to say they are there —
        // which is how "Apply now" ends up invisible on the screen where it matters most.
        VStack(alignment: .leading, spacing: 7) {
          FlowLayout(spacing: 7) {
                Button(action: confirm) { KeyLabel("\u{21A9}", "Confirm") }
                    .buttonStyle(.borderedProminent)
                Button(action: { editing = true }) { KeyLabel("E", "Edit name") }
                Button(action: copyCitation) { KeyLabel("B", "Citation") }
                    .tip("Copy its BibTeX entry, asking the model if fields are missing", key: "B")
                Toggle(isOn: $autoIdentify) {
                    Image(systemName: autoIdentify ? "sparkles.rectangle.stack.fill"
                                                   : "sparkles.rectangle.stack")
                }
                .toggleStyle(.button)
                .disabled(!aiReady)
                .tip(autoIdentify ? "Asking the model on each new file"
                                  : "Ask the model on each new file")
                Button(action: identify) { KeyLabel("G", "Ask AI") }
                    .disabled(!aiReady || runner.ai.isThinking(item))
                    .tip(aiReady ? "Read the opening pages and suggest a title"
                             : "Add an API key in Settings first", key: "G")
          }

          FlowLayout(spacing: 7) {
                Button(action: skip) { KeyLabel("S", "Skip") }
                    .tip("Leave this file exactly as it is", key: "S")
                Button(action: skipFolder) { KeyLabel("F", folderScopeLabel) }
                    .disabled(pendingInFolder == 0)
                    .tip("Skip the rest of \(folderName)", key: "F")
                if decision != nil {
                    Button(action: reopen) { KeyLabel("R", "Reopen") }
                }
                Button(action: applyNow) { KeyLabel("A", "Apply now") }
                    .disabled(decision == .applied)
                    .tint(Ink.green)
                    .tip("Rename this one file on disk now", key: "A")
                Button(action: moveTo) { KeyLabel("M", "Move to…") }
                    .tint(Ink.purple)
                Button(action: markDeleted) { KeyLabel("D", "Trash") }
                    .tint(Ink.red)
                    .tip("To the Trash on apply, recoverable", key: "D")
          }
        }
    }

    @ViewBuilder
    private var lockedOverlay: some View {
        if item.status == .locked {
            Label("No password matched, cannot be shown", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .fittedBackground(.regularMaterial, in: Capsule())
                .padding(10)
        }
    }

    @ViewBuilder
    private var decisionBadge: some View {
        switch decision {
        case .confirmed:
            Label("Confirmed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Ink.green)
        case .applied:
            Label("Applied", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Ink.green)
        case .skipped:
            Label("Skipped", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        case .deleted:
            Label("Will be trashed", systemImage: "trash.circle.fill")
                .foregroundStyle(Ink.red)
        case .moveTo(let folder):
            Label("Moving to \(folder.lastPathComponent)", systemImage: "arrow.right.circle.fill")
                .foregroundStyle(Ink.purple)
        case nil:
            Label("Not reviewed", systemImage: "circle.dotted")
                .foregroundStyle(.tertiary)
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
        HStack(spacing: 5) {
            Text(key)
                .font(.caption2.weight(.bold).monospaced())
                .frame(minWidth: 14, minHeight: 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(title)
        }
    }
}

/// A `PDFView` that fits the page to the pane's width and starts at the top of the
/// document, rather than shrinking the whole page to fit and centring it.
final class FitWidthPDFView: PDFView {
    private var wantsTopScroll = false

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
        let pageWidth = page.bounds(for: displayBox).width
        let width = availableWidth
        guard pageWidth > 0, width > 0 else { return }

        let target = min(max(width / pageWidth, minScaleFactor), maxScaleFactor)
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
        view.backgroundColor = .clear
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
            view.showFromTop()
            annotator?.attach(view, url: wanted)
        }
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
        VStack(alignment: .leading, spacing: 14) {
            heading
            group("File", rows: fileRows)
            suggested
            group("Reading", rows: readingRows)
            opening
            actions
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the book calls itself, in its own voice, with the tags under it.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(Face.section)
                    .foregroundStyle(.tertiary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(rows, id: \.0) { name, value in
                        GridRow {
                            Text(name)
                                .font(Face.caption)
                                .foregroundStyle(.tertiary)
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
            VStack(alignment: .leading, spacing: 3) {
                Text("Suggested name")
                    .font(Face.section)
                    .foregroundStyle(.tertiary)
                Text(item.sourceName)
                    .font(Face.mono)
                    .foregroundStyle(.tertiary)
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
        if let position, position.isInProgress {
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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Metric.control))
        } else if item.status == .locked {
            Label("Locked, so nothing inside can be read", systemImage: "lock.fill")
                .font(Face.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            if let read {
                Button(action: read) {
                    Label("Read", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tip("Open the page, its outline and your marks on it", key: "⏎")
            }
            HStack(spacing: 6) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.currentURL])
                }
                .frame(maxWidth: .infinity)
                Button("Quick Look") { QuickLook.show(item.currentURL) }
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Status
