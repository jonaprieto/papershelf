import SwiftUI
import PaperShelfCore

/// One open document: the page, the outline beside it, and the bar that says where you
/// are in it.
///
/// The reviewer and the reader were each drawing this, separately, with the same three
/// pieces and the same two bugs waiting in them. One view rather than two is what lets a
/// window hold more than one document at a time: a pane is an instance of this.
///
/// It knows about a URL and an `Annotator` and nothing else. Everything that needs the
/// palette, a document's meaning scopes or the ChatGPT handoff, the selection bar, the
/// mark bar, the locked overlay, is drawn by whoever hosts this and handed in through
/// `overlays`. That is the boundary that keeps this file small: those three bars pull in
/// half of `Review.swift` behind them.
struct DocumentPane<Overlay: View>: View {
    let url: URL
    let passwords: [String]
    var annotator: Annotator
    @Binding var fit: PageFit
    let appearance: PDFReadingAppearance
    var presentation = false
    /// Whether the outline is drawn as a column here. The host decides: it knows whether
    /// the reader asked for it, whether the document has pages to list, and whether the
    /// pane is narrow enough that it should be a popover instead.
    var showsContentsRail = true
    /// The region the outline claims when it is clicked, and none when the host hands in
    /// nothing.
    ///
    /// Focus is one thing for the whole process rather than one per window, so a rail that
    /// claims a region claims it everywhere: a reader opened from Finder took the arrow
    /// keys off an open library window's sidebar and greyed the shelf's selection, for a
    /// click in a window that had nothing to do with either. Only the window that keeps
    /// `Regions.available` honest asks for a claim.
    var railRegion: Region?
    /// The reader window puts its page controls in a row under the page, with the
    /// filename beside them, so it asks for no bar of its own here.
    var showsPageBar = true
    var onDocumentSwipe: ((Int) -> Void)?
    var onPageStep: ((Int) -> Void)?
    var onMarkClick: ((CGPoint) -> Void)?
    /// The point while the pointer is over the page, and nil when it leaves. One closure
    /// rather than two, because the host's two handlers are a pair: the bar is held up for
    /// a moment after the pointer leaves so it can be reached.
    var onPointer: ((CGPoint?) -> Void)?
    let openFind: () -> Void
    var togglePresentation: (() -> Void)?
    @ViewBuilder let overlays: () -> Overlay
    // Computed, not stored: a stored private property makes the memberwise initialiser
    // private too, and the memberwise initialiser is how a host builds a pane.
    private var prefs: Prefs { Prefs.shared }
    private var webArticle: WebArticle? {
        annotator.url == url ? annotator.webArticle : (articleURL == url ? savedArticle : nil)
    }
    @State private var savedArticle: WebArticle?
    @State private var articleURL: URL?
    @State private var showingLive = false

    var body: some View {
        VStack(spacing: 0) {
            if let webArticle {
                HStack(spacing: Space.step) {
                    Image(systemName: showingLive ? "globe" : "doc.text")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(webArticle.url.host ?? webArticle.title).font(.callout.weight(.medium))
                        Text("\(showingLive ? "Live website" : "Saved copy") · \(webArticle.capturedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(Face.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(showingLive ? "Saved copy" : "Open live") { showingLive.toggle() }
                        .fixedSize()
                        .help("Switch between this saved version and the live website. Save a new version to refresh its citation.")
                    Menu("Citation") {
                        Button("Copy BibTeX") { ChatGPTHandoff.copy(webArticle.bibtex) }
                        Button("Copy source URL") { ChatGPTHandoff.copy(webArticle.url.absoluteString) }
                    }
                    .fixedSize()
                    .help("Citation for this saved version, using the website's metadata")
                }
                .controlSize(.small)
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.snug)
                .background(.bar)
                Divider()
            }
            if showingLive, let webArticle {
                WebReader(previous: webArticle) { _ in showingLive = false }
            } else {
                savedPage
            }
        }
        .onChange(of: url) { _, _ in showingLive = false }
        .onChange(of: annotator.webArticle?.version, initial: true) { _, _ in
            if annotator.url == url, let article = annotator.webArticle {
                savedArticle = article
                articleURL = url
            }
        }
        .onChange(of: showingLive) { _, live in annotator.readingLiveWebsite = live }
        .onDisappear { annotator.readingLiveWebsite = false }
    }

    private var savedPage: some View {
        // The contents rail's width is read off the room the page actually got, so on a
        // pane too narrow for both it is the chapter list that narrows and not the page
        // that is squeezed to nothing, or worse, pushed off the edge.
        GeometryReader { page in
            // The divider goes with the rail rather than with the request for one. That
            // width ramps to nothing on a narrow pane, and a divider drawn anyway is a
            // line down the left edge of the page with no rail behind it, holding the
            // page a point in from the edge it should start at.
            let railWidth = showsContentsRail
                ? SplitLayout.contentsRailWidth(inspectorWidth: page.size.width)
                : 0
            HStack(spacing: 0) {
                if railWidth > 0 {
                    rail(width: railWidth)
                    Divider()
                }
                PDFPreview(url: url, passwords: passwords,
                           annotator: annotator, fit: fit,
                           appearance: appearance,
                           presentation: presentation,
                           onDocumentSwipe: onDocumentSwipe,
                           onPageStep: onPageStep,
                           onMarkClick: onMarkClick)
                .modifier(PDFReadingAppearanceModifier(appearance: appearance))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The page is an AppKit view hosted in SwiftUI, and a hosted view does
                // not honour the frame it was given while it is being resized: squeezed
                // narrow, it kept drawing at its old width, straight over the panel
                // beside it. Clipping is what actually holds it to its pane.
                .clipped()
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): onPointer?(point)
                    case .ended: onPointer?(nil)
                    }
                }
                .overlay(alignment: .topLeading) { overlays() }
                .overlay(alignment: .bottom) {
                    if showsPageBar && !presentation {
                        PageBar(annotator: annotator, fit: $fit, openFind: openFind,
                                presentation: presentation,
                                togglePresentation: togglePresentation)
                            .padding(.bottom, Space.roomy)
                    }
                }
                .contextMenu {
                    Menu("Highlight selection") {
                        ForEach(Palette.shared.styles(for: [.forDocument(url), .library])) { style in
                            Button(style.meaning) { _ = annotator.highlightSelection(colour: style.nsColor) }
                        }
                    }
                    .disabled(!annotator.hasSelection)
                    SelectionNoteButton(annotator: annotator, colour: .systemYellow)
                    Button("Copy selection") {
                        if let selection = annotator.selectionForHandoff() { ChatGPTHandoff.copy(selection.quoted) }
                    }
                    .disabled(!annotator.hasSelection)
                    Divider()
                    Button(annotator.bookmarkOnCurrentPage == nil
                           ? "Add Bookmark" : "Remove Bookmark") {
                        _ = annotator.toggleBookmark()
                    }
                    Button("Show Bookmarks") {
                        prefs.contentsShown = true
                        prefs.contentsRailMode = .bookmarks
                    }
                }
            }
            .clipped()
        }
    }

    /// The outline at the width the pane can spare, claiming the host's region if it was
    /// given one.
    @ViewBuilder private func rail(width: CGFloat) -> some View {
        let rail = ContentsRail(annotator: annotator, findActive: annotator.showsFind)
            .frame(width: width)
        if let railRegion {
            rail.region(railRegion)
        } else {
            rail
        }
    }
}
