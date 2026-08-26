import SwiftUI
import AppKit
import PDFKit
import PDFHammerCore

/// Owns the live `PDFView` for the file on screen, so selections can be turned into marks
/// and marks can be listed and jumped to.
///
/// Annotating writes to the file straight away, the way a reader does. That is outside the
/// preview-then-apply flow on purpose: a note is not a rename waiting to be approved, it
/// is a change to the document you are reading. It is recorded in the log, and it is the
/// one thing here that Undo does not cover.
@MainActor
final class Annotator: ObservableObject {
    @Published private(set) var marks: [Mark] = []
    @Published private(set) var hasSelection = false
    @Published private(set) var lastError: String?
    /// The mark being looked at, so the rail can show it and the page can point at it.
    @Published var selectedMark: UUID?

    struct Mark: Identifiable {
        let id = UUID()
        let page: Int
        let kind: String
        /// What the mark sits on, read off the page.
        let quoted: String
        let note: String
        let annotation: PDFAnnotation
    }

    weak var view: PDFView?
    private(set) var url: URL?

    func attach(_ view: PDFView, url: URL) {
        self.view = view
        self.url = url
        refresh()
    }

    func selectionChanged() {
        hasSelection = !(view?.currentSelection?.string?.isEmpty ?? true)
    }

    func refresh() {
        guard let document = view?.document else { marks = []; return }
        var found: [Mark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let type = annotation.type ?? "Note"
                guard type != "Popup" else { continue }   // the tail of a text note, not a mark
                let quoted = page.selection(for: annotation.bounds)?.string?
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
                found.append(Mark(page: index + 1, kind: type, quoted: quoted,
                                  note: annotation.contents ?? "", annotation: annotation))
            }
        }
        marks = found
    }

    /// Highlights whatever is selected. A selection can run across pages, so one mark is
    /// made per page it touches, which is how the geometry actually works.
    func highlightSelection(note: String = "") -> Int {
        guard let view, let selection = view.currentSelection else { return 0 }
        var made = 0
        for page in selection.pages {
            for bounds in selection.selectionsByLine()
                .filter({ $0.pages.contains(page) })
                .map({ $0.bounds(for: page) }) {
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                mark.color = .systemYellow
                if !note.isEmpty { mark.contents = note }
                page.addAnnotation(mark)
                made += 1
            }
        }
        guard made > 0 else { return 0 }
        save()
        view.clearSelection()
        hasSelection = false
        // Force a redraw: the annotations were added to the document, and the view does
        // not always notice on its own.
        view.layoutDocumentView()
        refresh()
        selectedMark = marks.last?.id
        return made
    }

    func remove(_ mark: Mark) {
        mark.annotation.page?.removeAnnotation(mark.annotation)
        if selectedMark == mark.id { selectedMark = nil }
        save()
        refresh()
    }

    /// Clears every mark from the document. Destructive and not undoable, so the caller
    /// asks first.
    func removeAll() {
        guard let document = view?.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations { page.removeAnnotation(annotation) }
        }
        selectedMark = nil
        save()
        refresh()
    }

    /// Rewrites the note on an existing mark.
    func setNote(_ text: String, on mark: Mark) {
        mark.annotation.contents = text
        save()
        refresh()
    }

    /// Scrolls to a mark and selects the text under it, which is what makes it findable:
    /// a highlight on a page you are not looking at is invisible by definition.
    func jump(to mark: Mark) {
        guard let view, let page = mark.annotation.page else { return }
        selectedMark = mark.id
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: mark.annotation.bounds.maxY)))
        if let selection = page.selection(for: mark.annotation.bounds) {
            view.setCurrentSelection(selection, animate: true)
        }
    }

    /// Writes through a temporary file, so an interrupted save cannot leave a half-written
    /// document where the original was.
    private func save() {
        guard let document = view?.document, let url else { return }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".pdfhammer-notes-\(UUID().uuidString).pdf")
        guard document.write(to: temporary) else {
            lastError = "Could not write the note"
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            lastError = nil
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            lastError = error.localizedDescription
        }
    }
}
