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
    /// Where the selection sits, in the preview's own coordinates, so the bar can be put
    /// next to it rather than parked at the bottom of the page.
    @Published private(set) var selectionRect: CGRect?
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
        /// What it was painted with, read back off the annotation.
        let colour: NSColor
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
        guard let view, let selection = view.currentSelection,
              !(selection.string?.isEmpty ?? true), let page = selection.pages.first else {
            hasSelection = false
            selectionRect = nil
            return
        }
        hasSelection = true

        // Union of the lines on the first page the selection touches.
        let lines = selection.selectionsByLine()
            .filter { $0.pages.contains(page) }
            .map { view.convert($0.bounds(for: page), from: page) }
        guard let first = lines.first else {
            selectionRect = nil
            return
        }
        let box = lines.dropFirst().reduce(first) { $0.union($1) }
        // AppKit measures from the bottom, SwiftUI from the top.
        selectionRect = CGRect(x: box.minX, y: view.bounds.height - box.maxY,
                               width: box.width, height: box.height)
    }

    func refresh() {
        guard let document = view?.document else { marks = []; return }
        var found: [Mark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let type = annotation.type ?? "Note"
                guard type != "Popup" else { continue }   // the tail of a text note, not a mark
                let quoted = quotedText(of: annotation, on: page)
                found.append(Mark(page: index + 1, kind: type, quoted: quoted,
                                  note: annotation.contents ?? "",
                                  colour: annotation.color,
                                  annotation: annotation))
            }
        }
        marks = found
    }

    /// The text a mark covers. Read per quad where there are quads: the bounding box of
    /// a mark spanning two lines also covers the start of the line between them.
    private func quotedText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        let quads = annotation.quadrilateralPoints ?? []
        var boxes: [CGRect] = []
        if quads.count >= 4 {
            for start in stride(from: 0, to: quads.count - 3, by: 4) {
                let points = (0..<4).map { quads[start + $0].pointValue }
                let xs = points.map(\.x), ys = points.map(\.y)
                boxes.append(CGRect(x: xs.min()! + annotation.bounds.minX,
                                    y: ys.min()! + annotation.bounds.minY,
                                    width: xs.max()! - xs.min()!,
                                    height: ys.max()! - ys.min()!))
            }
        } else {
            boxes = [annotation.bounds]
        }
        let pieces = boxes.compactMap { page.selection(for: $0)?.string }
        return pieces.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Highlights whatever is selected.
    ///
    /// One annotation per page, not one per line. A highlight has to follow the line
    /// boxes to look right, but that is what `quadrilateralPoints` is for: several quads
    /// on one annotation. Making one annotation per line drew the same thing and then
    /// reported a two-line highlight as two separate marks, which is not what was made.
    ///
    /// A selection crossing a page break still yields one mark per page, because an
    /// annotation belongs to a page and cannot span two.
    @discardableResult
    func highlightSelection(colour: NSColor, note: String = "") -> Int {
        guard let view, let selection = view.currentSelection else { return 0 }
        var made = 0

        for page in selection.pages {
            let lines = selection.selectionsByLine()
                .filter { $0.pages.contains(page) }
                .map { $0.bounds(for: page) }
                .filter { $0.width > 0 && $0.height > 0 }
            guard !lines.isEmpty else { continue }

            let union = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
            let mark = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            mark.color = colour
            if !note.isEmpty { mark.contents = note }
            // Quads are given in the annotation's own coordinate space.
            mark.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
                let box = line.offsetBy(dx: -union.minX, dy: -union.minY)
                return [
                    NSValue(point: NSPoint(x: box.minX, y: box.maxY)),
                    NSValue(point: NSPoint(x: box.maxX, y: box.maxY)),
                    NSValue(point: NSPoint(x: box.minX, y: box.minY)),
                    NSValue(point: NSPoint(x: box.maxX, y: box.minY)),
                ]
            }
            page.addAnnotation(mark)
            made += 1
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

    /// Repaints an existing mark.
    func setColour(_ colour: NSColor, on mark: Mark) {
        mark.annotation.color = colour
        save()
        view?.layoutDocumentView()
        refresh()
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
