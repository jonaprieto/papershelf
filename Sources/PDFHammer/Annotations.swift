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
    /// The document's own table of contents, if it has one.
    @Published private(set) var contents: [Chapter] = []
    /// The page on screen, one-based, and how many there are. Published so the Info panel
    /// can say where you are, and written to the library so the shelf can say which books
    /// are open.
    @Published private(set) var page = 1
    @Published private(set) var pageCount = 0

    /// One outline entry, flattened with its depth. A table of contents is read top to
    /// bottom far more often than it is folded, and indentation carries the structure
    /// without a disclosure triangle on every line.
    struct Chapter: Identifiable {
        let id = UUID()
        let label: String
        let level: Int
        let page: Int?
        let destination: PDFDestination?
    }

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

    /// Bumped on every attach, so a scan still walking the file you just left stops
    /// instead of publishing its marks over the one you are looking at now.
    private var generation = 0
    private var scan: Task<Void, Never>?

    /// A save waiting out the pause after the last edit, and whether there is anything to
    /// write. Recolouring a mark or typing a note used to serialize the whole document on
    /// every keystroke; now a burst of edits costs one write.
    private var saveTask: Task<Void, Never>?
    private var unsaved = false

    /// The last position written to the library, and the write waiting out a scroll. A
    /// page turn is cheap; a database write per scroll tick is not.
    private var positionTask: Task<Void, Never>?
    private var writtenPage: Int?

    func attach(_ view: PDFView, url: URL) {
        // Whatever the previous document still owed the disk, it owes now: the debounce
        // must never outlive the file it was waiting for.
        flush()
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
        self.view = view
        self.url = url
        generation &+= 1
        marks = []
        writtenPage = nil
        pageCount = view.document?.pageCount ?? 0
        page = 1
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        restorePosition()
        // Cheap: a couple of milliseconds even on a long book, and the rail beside the
        // page would look broken without it.
        readContents()
        startScanningForMarks()
    }

    /// Walks the pages for marks a slice at a time, giving the run loop a turn between
    /// slices.
    ///
    /// Reading one page's annotations costs a fraction of a millisecond and a thesis has
    /// two hundred pages, so doing the whole walk at once held the main thread for about a
    /// tenth of a second every time the selection moved. The pages belong to the view's
    /// own document, which is the main thread's, so this cannot be moved off it: it is
    /// broken up instead, and abandoned the moment another file is attached.
    private func startScanningForMarks() {
        scan?.cancel()
        let mine = generation
        scan = Task { @MainActor [weak self] in
            guard let self, let document = self.view?.document else { return }
            var found: [Mark] = []
            for index in 0..<document.pageCount {
                if index % 16 == 15 { await Task.yield() }
                guard !Task.isCancelled, mine == self.generation else { return }
                guard let page = document.page(at: index) else { continue }
                found.append(contentsOf: self.marks(on: page, page: index + 1))
            }
            guard !Task.isCancelled, mine == self.generation else { return }
            self.marks = found
        }
    }

    /// One page's marks. Shared by the slice-at-a-time scan and the whole-document
    /// `refresh` an edit triggers, so the two cannot disagree about what a mark is.
    private func marks(on page: PDFPage, page number: Int) -> [Mark] {
        page.annotations.compactMap { annotation in
            let type = annotation.type ?? "Note"
            guard type != "Popup" else { return nil }   // the tail of a text note, not a mark
            return Mark(page: number, kind: type, quoted: quotedText(of: annotation, on: page),
                        note: annotation.contents ?? "",
                        colour: annotation.color,
                        annotation: annotation)
        }
    }

    /// The page turned to, remembered.
    ///
    /// Debounced: scrolling a long document walks through pages several a second, and a
    /// write for each of them is a database transaction per scroll tick. What is
    /// published moves immediately; only the trip to the library waits.
    @objc private func pageChanged() {
        guard let view, let document = view.document, let current = view.currentPage else { return }
        page = document.index(for: current) + 1
        pageCount = document.pageCount
        positionTask?.cancel()
        let mine = generation
        positionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.writePosition(generation: mine)
        }
    }

    private func writePosition(generation mine: Int) async {
        guard mine == generation, let url, page != writtenPage,
              let library = Library.shared else { return }
        let path = url.resolvingSymlinksInPath().path
        let here = page
        let total = pageCount > 0 ? pageCount : nil
        writtenPage = here
        guard let record = try? await library.document(atPath: path) else { return }
        try? await library.rememberReadingPosition(documentID: record.id, page: here,
                                                   pageCount: total)
    }

    /// Opens a book where it was left, which is what makes remembering the page worth
    /// anything. A document the library has never seen simply opens at the top.
    private func restorePosition() {
        guard let url, let library = Library.shared else { return }
        let path = url.resolvingSymlinksInPath().path
        let mine = generation
        Task { [weak self] in
            guard let record = try? await library.document(atPath: path),
                  let position = try? await library.readingPosition(forDocument: record.id),
                  position.isInProgress
            else { return }
            await MainActor.run {
                guard let self, mine == self.generation, let view = self.view,
                      let document = view.document,
                      let page = document.page(at: min(position.page, document.pageCount) - 1)
                else { return }
                view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
                self.page = position.page
                self.writtenPage = position.page
            }
        }
    }

    private func readContents() {
        guard let document = view?.document, let root = document.outlineRoot else {
            contents = []
            return
        }
        var found: [Chapter] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let page = child.destination?.page.map { document.index(for: $0) + 1 }
                found.append(Chapter(label: child.label ?? "Untitled", level: level,
                                     page: page, destination: child.destination))
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        contents = found
    }

    /// Turns to a page, one-based, clamped to the document. The palette's `:` and the
    /// jump that follows a full-text hit both come through here.
    func go(toPage number: Int) {
        guard let view, let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(max(number, 1), document.pageCount) - 1)
        else { return }
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
    }

    /// What the open document says about a phrase: the page, the line it sits on, and a
    /// way back to it. The palette's `/` is this, and nothing else in the app could
    /// answer it -- the library's index knows the text of every document except the one
    /// being read, which may have been edited since it was indexed.
    func find(_ text: String, limit: Int = 8) -> [(page: Int, line: String, jump: () -> Void)] {
        guard let view, let document = view.document, text.count > 1 else { return [] }
        let matches = document.findString(text, withOptions: [.caseInsensitive])
        return matches.prefix(limit).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let number = document.index(for: page) + 1
            let line = selection.string ?? text
            return (page: number, line: line, jump: { [weak view] in
                view?.go(to: selection)
                view?.setCurrentSelection(selection, animate: true)
            })
        }
    }

    func go(to chapter: Chapter) {
        guard let view, let destination = chapter.destination else { return }
        view.go(to: destination)
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

    /// What a live selection would hand to ChatGPT: the passage, the page it sits on, and
    /// a title for context. A selection is not a mark yet, so there is no stored page
    /// number or note the way `Mark` has them; both are read straight off the current
    /// selection and the file on screen, the same way `highlightSelection` reads the
    /// selection fresh rather than from a cached property.
    func selectionForHandoff() -> (quoted: String, page: Int, title: String)? {
        guard let view, let selection = view.currentSelection,
              let quoted = selection.string, !quoted.isEmpty,
              let page = selection.pages.first, let document = view.document else { return nil }
        let title = url?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return (quoted: quoted, page: document.index(for: page) + 1, title: title)
    }

    /// The whole document at once, for the moment right after an edit, where waiting a
    /// turn of the run loop would show the mark appearing late.
    func refresh() {
        guard let document = view?.document else { marks = []; return }
        // An edit lands on the file already open, so anything the slice-at-a-time scan is
        // still doing is about to be redundant.
        scan?.cancel()
        var found: [Mark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            found.append(contentsOf: marks(on: page, page: index + 1))
        }
        marks = found
    }

    /// The text a mark covers, from PDFHammerCore, which is also what the MCP server
    /// reads so that both see the same thing.
    private func quotedText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        PDFHammerCore.quotedText(of: annotation, on: page)
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

    /// Marks the document dirty and waits out a short pause before writing.
    ///
    /// The mark itself is already on the page, so the reader sees it immediately; what is
    /// deferred is only the trip to disk. Dragging through a paragraph, recolouring it and
    /// typing a note is one write instead of a dozen.
    private func save() {
        unsaved = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Writes right now, whatever the pause was waiting for. Called before another
    /// document is attached and when the reader goes away, so nothing is ever lost to the
    /// delay — and so a save can never land on the file that replaced the one it was for.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    /// Serializes on the main actor — the document belongs to the view, and PDFKit will
    /// not have it read from two threads at once — then hands the finished bytes to a
    /// detached task for the part that actually waits on hardware.
    ///
    /// Both the document and its URL are read here, synchronously, rather than inside the
    /// task: by the time a task runs, `attach` may already have pointed this object at a
    /// different file.
    private func persist() {
        guard unsaved, let document = view?.document, let url else { return }
        guard let data = document.dataRepresentation() else {
            lastError = "Could not write the note"
            return
        }
        unsaved = false
        Task { [weak self] in
            let failure = await Annotator.persist(data, to: url)
            await MainActor.run { self?.lastError = failure }
        }
    }

    /// Writing through a temporary file means an interrupted save cannot leave a
    /// half-written document where the original was.
    private nonisolated static func persist(_ data: Data, to url: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".pdfhammer-notes-\(UUID().uuidString).pdf")
            do {
                try data.write(to: temporary, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                return nil
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return error.localizedDescription
            }
        }.value
    }
}
