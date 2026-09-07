import SwiftUI
import AppKit
import PDFKit
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

    var body: some View {
        // The contents rail's width is read off the room the page actually got, so on a
        // pane too narrow for both it is the chapter list that narrows and not the page
        // that is squeezed to nothing, or worse, pushed off the edge.
        GeometryReader { page in
            HStack(spacing: 0) {
                if showsContentsRail {
                    ContentsRail(annotator: annotator, findActive: annotator.showsFind)
                        .frame(width: SplitLayout.contentsRailWidth(
                            inspectorWidth: page.size.width))
                        .region(.contents)
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
}
