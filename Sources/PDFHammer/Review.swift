import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

struct ReviewInspector: View {
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
    @AppStorage("notesShown") private var notesShown = false
    @AppStorage("contentsShown") private var contentsShown = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                // The rail's width is read off the room this inspector actually got, so on
                // a window too narrow for both it is the chapter list that narrows and not
                // the page that is squeezed to nothing, or worse, pushed off the edge.
                GeometryReader { inspector in
                HStack(spacing: 0) {
                    if contentsShown && !annotator.contents.isEmpty {
                        ContentsRail(annotator: annotator,
                                     close: { contentsShown = false })
                            .frame(width: SplitLayout.contentsRailWidth(
                                inspectorWidth: inspector.size.width))
                        Divider()
                    }
                    PDFPreview(url: item.currentURL, passwords: passwords, annotator: annotator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.35))
                    .overlay(alignment: .topTrailing) { lockedOverlay }
                    .overlay(alignment: .topLeading) { floatingSelectionBar }
                }
                }

                Divider()
                panelHeader

                if showBottom {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            switch panel {
                            case .rename: renamePanel
                            case .details: MetadataPanel(item: item, excerpt: excerpt, tags: tags)
                            case .bibtex: bibtexPanel
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
        }
        .onAppear { if draft.isEmpty { draft = item.destinationName } }
        .onChange(of: item.key) { _, _ in
            editing = false
            addingNote = false
            noteText = ""
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

            if !annotator.contents.isEmpty {
                Button {
                    contentsShown.toggle()
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(contentsShown ? Color.accentColor : .secondary)
                .tip(contentsShown ? "Hide the contents" : "Table of contents", key: "⌘⇧T")
            }

            Button(action: reveal) { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .tip("Reveal in Finder", key: "⌘R")
            Button(action: openExternally) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .tip("Open in the default PDF viewer", key: "O")

            Button {
                notesShown.toggle()
            } label: {
                if reading {
                    Label(notesShown ? "Hide notes" : "Notes",
                          systemImage: notesShown ? "sidebar.trailing" : "note.text")
                } else {
                    Image(systemName: notesShown ? "sidebar.trailing" : "note.text")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(notesShown ? Color.accentColor : .secondary)
            .help(notesShown ? "Hide the notes (⌘⇧N)" : "Show notes and highlights (⌘⇧N)")
            .overlay(alignment: .topTrailing) {
                if !annotator.marks.isEmpty && !notesShown {
                    Circle()
                        .fill(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
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
                let bar = CGSize(width: ChatGPTHandoff.isInstalled ? 284 : 250, height: 40)
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
                    notesShown = true
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
                notesShown = true
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
            if ChatGPTHandoff.isInstalled {
                Menu {
                    Button("Open in ChatGPT") { handOffSelection(copyOnly: false) }
                    Button("Copy for ChatGPT") { handOffSelection(copyOnly: true) }
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
                        .foregroundStyle(Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255)))
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
                .foregroundStyle(item.status == .failed ? .red : .orange)
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
        VStack(spacing: 7) {
          ScrollView(.horizontal) {
            HStack(spacing: 7) {
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
                    .disabled(!aiReady || runner.isThinking(item))
                    .tip(aiReady ? "Read the opening pages and suggest a title"
                             : "Add an API key in Settings first", key: "G")
                Spacer(minLength: 0)
            }
          }
          .scrollIndicators(.hidden)

          ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Button(action: skip) { KeyLabel("S", "Skip") }
                    .tip("Leave this file exactly as it is", key: "S")
                Button(action: skipFolder) { KeyLabel("F", folderScopeLabel) }
                    .disabled(pendingInFolder == 0)
                    .tip("Skip the rest of \(folderName)", key: "F")
                if decision != nil {
                    Button(action: reopen) { KeyLabel("R", "Reopen") }
                }
                Spacer(minLength: 0)
                Button(action: applyNow) { KeyLabel("A", "Apply now") }
                    .disabled(decision == .applied)
                    .tint(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    .tip("Rename this one file on disk now", key: "A")
                Button(action: moveTo) { KeyLabel("M", "Move to…") }
                    .tint(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
                Button(action: markDeleted) { KeyLabel("D", "Trash") }
                    .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                    .tip("To the Trash on apply, recoverable", key: "D")
            }
          }
          .scrollIndicators(.hidden)
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
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .applied:
            Label("Applied", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .skipped:
            Label("Skipped", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        case .deleted:
            Label("Will be trashed", systemImage: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
        case .moveTo(let folder):
            Label("Moving to \(folder.lastPathComponent)", systemImage: "arrow.right.circle.fill")
                .foregroundStyle(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
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
                .frame(width: 14, height: 14)
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
    case rename, details, bibtex
    var id: String { rawValue }

    var label: String {
        switch self {
        case .rename: return "Rename"
        case .details: return "Details"
        case .bibtex: return "BibTeX"
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

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        for key in ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"] {
            if let value = item.documentInfo[key] { rows.append((key.lowercased(), value)) }
        }
        if let date = item.metadataDate {
            rows.append(("created", date.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }

    private var physical: String {
        [
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            item.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" },
            item.modifiedDate.map { "modified \($0.formatted(date: .abbreviated, time: .omitted))" },
        ].compactMap { $0 }.joined(separator: "   ·   ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(physical)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            TagStrip(actions: tags)

            if !facts.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .gridColumnAlignment(.trailing)
                            Text(value)
                                .font(.caption)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            } else if item.status == .locked {
                Label("Locked, so nothing inside can be read", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status
