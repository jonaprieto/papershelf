import SwiftUI
import AppKit
import PaperShelfCore

/// An editable BibTeX entry that is coloured as it is typed.
///
/// `TextEditor` holds a `String` and nothing else, so the entry beside a document was a
/// wall of one-colour monospace while the same entry in the bibliography view was
/// coloured -- the one place you are actually editing an entry was the one place that
/// would not show you its shape. SwiftUI cannot hold an `AttributedString` in an editor
/// before macOS 15, so this is an `NSTextView` with the app's own highlighter run over it
/// on every change.
///
/// The colours come from `bibtexTokens`, whose tokens rebuild their input exactly (a test
/// in Core holds that), so what is coloured is character for character what Copy, Store
/// and Save produce.
struct BibtexEditor: NSViewRepresentable {
    @Binding var text: String
    /// Reported back so the pane around it can be as tall as the entry. The editor does
    /// not scroll: it sits in a pane that already does, and a scroll view inside a scroll
    /// view is what clipped the closing brace and the DOI off the end of an entry.
    var height: (CGFloat) -> Void = { _ in }

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = BibtexEditor.font
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 3
        // Every one of these turns a straight quote into a curly one, a pair of hyphens
        // into a dash, or a brace into something else. A .bib is not prose: substituted
        // punctuation is a broken entry, and it breaks silently.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        // Only when it actually differs. Assigning `string` on every pass would move the
        // insertion point to the end of the entry on every keystroke.
        if view.string != text {
            let selected = view.selectedRange()
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
        }
        context.coordinator.recolour(view)
        context.coordinator.report(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BibtexEditor
        private var lastReported: CGFloat = 0

        init(_ parent: BibtexEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            recolour(view)
            report(view)
        }

        /// Paints the entry. Attributes are set on the storage rather than the string
        /// being replaced, so the insertion point and any selection stay where they were.
        func recolour(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let text = view.string
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: BibtexEditor.font,
                                   .foregroundColor: NSColor.labelColor], range: whole)
            var location = 0
            for token in bibtexTokens(text) {
                let length = (token.text as NSString).length
                defer { location += length }
                guard let colour = BibtexEditor.colour(for: token.kind) else { continue }
                let range = NSRange(location: location, length: length)
                guard NSMaxRange(range) <= storage.length else { break }
                storage.addAttribute(.foregroundColor, value: colour, range: range)
                if token.kind == .entryType || token.kind == .key {
                    storage.addAttribute(.font, value: BibtexEditor.bold, range: range)
                }
            }
            storage.endEditing()
        }

        /// How tall the entry is, once laid out. Measured from the text itself rather
        /// than counted in lines, so wrapping is accounted for.
        func report(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let height = (used + view.textContainerInset.height * 2).rounded(.up)
            guard abs(height - lastReported) > 0.5 else { return }
            lastReported = height
            // Out of this layout pass: reporting a height that changes a frame from
            // inside `updateNSView` is a modification during view updates.
            DispatchQueue.main.async { [parent] in parent.height(height) }
        }
    }

    private static let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    /// The same five colours the bibliography view reads its entries in. Named once here
    /// in AppKit terms; `highlighted(_:)` is the SwiftUI half of the same palette.
    static func colour(for kind: BibTokenKind) -> NSColor? {
        switch kind {
        case .entryType: return NSColor(Ink.magenta)
        case .key: return NSColor(Ink.blue)
        case .field: return NSColor(Ink.amber)
        case .value: return NSColor(Ink.green)
        case .punctuation: return .secondaryLabelColor
        case .plain: return nil
        }
    }
}
