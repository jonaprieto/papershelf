import SwiftUI
import AppKit
import PDFKit
import PaperShelfCore

/// Owns the live `PDFView` for the file on screen, so selections can be turned into marks
/// and marks can be listed and jumped to.
///
/// Annotating writes to the file straight away, the way a reader does. That is outside the
/// preview-then-apply flow on purpose: a note is not a rename waiting to be approved, it
/// is a change to the document you are reading. It is recorded in the log, and it is the
/// one thing here that Undo does not cover.
@MainActor
@Observable
final class Annotator {
    private(set) var marks: [Mark] = []
    private(set) var hasSelection = false
    /// Where the selection sits, in the preview's own coordinates, so the bar can be put
    /// next to it rather than parked at the bottom of the page.
    private(set) var selectionRect: CGRect?
    private(set) var lastError: String?
    /// The mark being looked at, so the rail can show it and the page can point at it.
    var selectedMark: UUID?
    /// The document's own table of contents, if it has one.
    private(set) var contents: [Chapter] = []
    /// Named return points kept in the library, separate from PDF annotations.
    private(set) var bookmarks: [Bookmark] = []
    /// The transient Find session for the document on screen. This belongs to the live
    /// PDF rather than the library index: a file can be found before a scan, and after it
    /// has changed on disk but before a later indexing pass reaches it.
    var showsFind = false
    private(set) var findFocusToken = 0
    var findQuery = ""
    private(set) var findHits: [FindHit] = []
    private(set) var selectedFindHit: Int?
    /// The sibling Markdown companion's last write, so the Notes rail can say whether
    /// the file on disk still matches this PDF.
    private(set) var notesSidecarDate: Date?
    /// The page on screen, one-based, and how many there are. Published so the Info panel
    /// can say where you are, and written to the library so the shelf can say which books
    /// are open.
    private(set) var page = 1
    private(set) var pageCount = 0

    /// What the open document says it is called, and by whom.
    ///
    /// Read off the file on screen rather than from the plan. The plan carries these too,
    /// but only once a run has read the file, so a window opened straight onto a document
    /// was titled with its filename until somebody pressed Review names.
    private(set) var statedTitle: String?
    private(set) var statedAuthor: String?

    /// Whether there is a document to look at from the side. The rail shows the outline
    /// where there is one and the pages themselves where there is not, so what it needs
    /// is pages, not chapters -- a scan has none of the latter and is exactly the kind of
    /// document a column of thumbnails is for.
    var hasPages: Bool { pageCount > 0 }
    var hasBookmarks: Bool { !bookmarks.isEmpty }
    var bookmarkOnCurrentPage: Bookmark? {
        bookmarks.first { $0.page == page }
    }

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
        let id: UUID
        let page: Int
        let kind: String
        /// What the mark sits on, read off the page.
        let quoted: String
        let note: String
        /// What it was painted with, read back off the annotation.
        let colour: NSColor
        /// When this mark was last changed, read from the PDF annotation.
        let timestamp: Date
        let annotation: PDFAnnotation

        init(id: UUID = UUID(), page: Int, kind: String, quoted: String, note: String,
             colour: NSColor, timestamp: Date? = nil, annotation: PDFAnnotation) {
            self.id = id
            self.page = page
            self.kind = kind
            self.quoted = quoted
            self.note = note
            self.colour = colour
            self.timestamp = timestamp ?? annotation.modificationDate ?? Date()
            self.annotation = annotation
        }
    }

    /// One exact match in the live PDF. Keeping PDFKit's selection is what lets a list
    /// row return to the right instance of a repeated phrase, rather than merely to its
    /// page.
    struct FindHit: Identifiable {
        let id: Int
        let page: Int
        let text: String
        fileprivate let selection: PDFSelection
    }

    /// Marks in reading order: by page, then down the page, then across it.
    ///
    /// Both ways marks arrive are out of order on their own. The initial scan takes each
    /// page's annotations in the order the file stores them, which is the order they were
    /// made rather than where they sit; and a new highlight was appended, so a passage
    /// marked on page 1 landed under one from page 7. Sorting here is what makes the list
    /// beside the page agree with the page.
    static func precedes(_ first: Mark, _ second: Mark) -> Bool {
        if first.page != second.page { return first.page < second.page }
        let top = first.annotation.bounds.maxY
        let other = second.annotation.bounds.maxY
        // PDF coordinates grow upwards, so the higher box is the earlier line. A point of
        // slack keeps two marks on the same line ordered left to right instead of by a
        // rounding difference in their heights.
        if abs(top - other) > 1 { return top > other }
        return first.annotation.bounds.minX < second.annotation.bounds.minX
    }

    weak var view: PDFView?
    private(set) var url: URL?
    private(set) var documentID: String?

    /// Bumped on every attach, so a scan still walking the file you just left stops
    /// instead of publishing its marks over the one you are looking at now.
    private var generation = 0
    private var scan: Task<Void, Never>?

    /// A save waiting out the pause after the last edit, and whether there is anything to
    /// write. Recolouring a mark or typing a note used to serialize the whole document on
    /// every keystroke; now a burst of edits costs one write.
    private var saveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var unsaved = false

    /// The last position written to the library, and the write waiting out a scroll. A
    /// page turn is cheap; a database write per scroll tick is not.
    private var positionTask: Task<Void, Never>?
    private var writtenPage: Int?
    private var bookmarksTask: Task<Void, Never>?

    func attach(_ view: PDFView, url: URL) {
        // Whatever the previous document still owed the disk, it owes now: the debounce
        // must never outlive the file it was waiting for.
        flush()
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
        self.view = view
        self.url = url
        documentID = nil
        generation &+= 1
        marks = []
        contents = []
        bookmarksTask?.cancel()
        bookmarksTask = nil
        bookmarks = []
        closeFind()
        notesSidecarDate = sidecarDate(for: url)
        writtenPage = nil
        pageCount = view.document?.pageCount ?? 0
        page = 1
        let attributes = view.document?.documentAttributes
        statedTitle = stated(attributes?[PDFDocumentAttribute.titleAttribute])
        statedAuthor = stated(attributes?[PDFDocumentAttribute.authorAttribute])
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        restorePosition()
        // Outline and annotation walks are deferred one run-loop turn. The PDF page can
        // paint and accept keyboard input before a long book's notes have been indexed.
        let mine = generation
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, mine == self.generation else { return }
            self.readContents()
            self.startScanningForMarks()
        }
    }

    func setDocumentID(_ id: String?) {
        documentID = id
        bookmarksTask?.cancel()
        bookmarksTask = nil
        bookmarks = []
        loadBookmarks()
    }

    private func loadBookmarks() {
        guard let documentID, let library = Library.shared else { return }
        let mine = generation
        bookmarksTask = Task { @MainActor [weak self] in
            let loaded = try? await library.bookmarks(forDocument: documentID)
            guard let self, mine == self.generation, self.documentID == documentID else { return }
            self.bookmarks = loaded ?? []
            self.bookmarksTask = nil
        }
    }

    /// Adds or removes the bookmark on the current page. The immediate Boolean lets a
    /// command report whether it had a document to act on; the database work stays off
    /// the button's synchronous path.
    @discardableResult
    func toggleBookmark() -> Bool {
        guard hasPages, let url, let library = Library.shared else { return false }
        let targetPage = page
        let mine = generation
        bookmarksTask?.cancel()
        bookmarksTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let documentID: String
            if let existing = self.documentID {
                documentID = existing
            } else {
                let file = url.resolvingSymlinksInPath()
                let input = await Task.detached { indexInput(for: file) }.value
                guard let record = (try? await library.indexDocuments([input]))?.first,
                      mine == self.generation else { return }
                documentID = record.id
                self.documentID = documentID
            }
            let existing: Bookmark?
            do {
                existing = try await library.bookmark(documentID: documentID, page: targetPage)
            } catch {
                return
            }
            if let existing {
                try? await library.removeBookmark(existing.id)
            } else {
                _ = try? await library.addBookmark(documentID: documentID, page: targetPage)
            }
            guard mine == self.generation, self.documentID == documentID else { return }
            self.bookmarks = (try? await library.bookmarks(forDocument: documentID)) ?? []
            self.bookmarksTask = nil
        }
        return true
    }

    @discardableResult
    func removeBookmark(_ bookmark: Bookmark) -> Bool {
        guard bookmark.documentID == documentID, let library = Library.shared else { return false }
        let mine = generation
        bookmarksTask?.cancel()
        bookmarksTask = Task { @MainActor [weak self] in
            try? await library.removeBookmark(bookmark.id)
            guard let self, mine == self.generation, self.documentID == bookmark.documentID else { return }
            self.bookmarks = (try? await library.bookmarks(forDocument: bookmark.documentID)) ?? []
            self.bookmarksTask = nil
        }
        return true
    }

    @discardableResult
    func renameBookmark(_ bookmark: Bookmark, label: String) -> Bool {
        guard bookmark.documentID == documentID, let library = Library.shared else { return false }
        let mine = generation
        bookmarksTask?.cancel()
        bookmarksTask = Task { @MainActor [weak self] in
            _ = try? await library.renameBookmark(bookmark.id, label: label)
            guard let self, mine == self.generation, self.documentID == bookmark.documentID else { return }
            self.bookmarks = (try? await library.bookmarks(forDocument: bookmark.documentID)) ?? []
            self.bookmarksTask = nil
        }
        return true
    }

    func jump(to bookmark: Bookmark) {
        guard bookmark.documentID == documentID else { return }
        go(toPage: bookmark.page)
    }

    /// A document attribute worth showing: a string, with something in it. PDFs written
    /// by LaTeX routinely carry an empty title, and a window titled "" is worse than one
    /// titled with the filename.
    private func stated(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            await Task.yield()
            var found: [Mark] = []
            for index in 0..<document.pageCount {
                if index % 4 == 3 { await Task.yield() }
                guard !Task.isCancelled, mine == self.generation else { return }
                guard let page = document.page(at: index) else { continue }
                found.append(contentsOf: self.marks(on: page, page: index + 1))
            }
            guard !Task.isCancelled, mine == self.generation else { return }
            self.marks = found.sorted(by: Annotator.precedes)
            self.scan = nil
        }
    }

    private func rescanIfNeeded() {
        guard scan != nil else { return }
        startScanningForMarks()
    }

    /// One page's marks. Keeping this as the single annotation projection means the
    /// initial scan and any future rescan cannot disagree about what a mark is.
    /// What counts as a mark: something a reader put on the page.
    ///
    /// Not every annotation is one. A paper built by LaTeX carries a Link annotation for
    /// every citation and cross-reference, and a form carries a Widget for every field;
    /// listing those in the notes rail buried four real highlights under forty
    /// hyperlinks. Popup is the tail of a text note rather than a mark of its own.
    private static let markTypes: Set<String> = [
        "Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText", "Ink",
    ]

    private func marks(on page: PDFPage, page number: Int) -> [Mark] {
        page.annotations.compactMap { annotation in
            let type = annotation.type ?? "Note"
            guard Annotator.markTypes.contains(type) else { return nil }
            let id = marks.first { $0.annotation === annotation }?.id ?? UUID()
            return Mark(id: id, page: number, kind: type,
                        quoted: quotedText(of: annotation, on: page),
                        note: annotation.contents ?? "", colour: annotation.color,
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

    func openFind() {
        guard hasPages else { return }
        findFocusToken &+= 1
        showsFind = true
        updateFindHits()
    }

    func closeFind() {
        showsFind = false
        findQuery = ""
        findHits = []
        selectedFindHit = nil
    }

    /// Replaces the visible hit list for the current query. PDFKit owns this document on
    /// the main actor, so the lookup stays here with the view rather than racing it from
    /// a background task.
    func updateFindHits() {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = view?.document, !query.isEmpty else {
            findHits = []
            selectedFindHit = nil
            return
        }
        findHits = document.findString(query, withOptions: [.caseInsensitive]).enumerated()
            .compactMap { index, selection in
                guard let page = selection.pages.first else { return nil }
                return FindHit(id: index, page: document.index(for: page) + 1,
                               text: Self.findLabel(selection.string ?? query), selection: selection)
            }
        selectedFindHit = findHits.isEmpty ? nil : 0
        if !findHits.isEmpty { selectFindHit(at: 0) }
    }

    func selectFindHit(at index: Int) {
        guard findHits.indices.contains(index), let view else { return }
        let hit = findHits[index]
        selectedFindHit = index
        view.go(to: hit.selection)
        view.setCurrentSelection(hit.selection, animate: true)
    }

    func stepFind(by delta: Int) {
        guard !findHits.isEmpty else { return }
        let current = selectedFindHit ?? (delta > 0 ? -1 : 0)
        selectFindHit(at: (current + delta + findHits.count) % findHits.count)
    }

    private static func findLabel(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
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

    /// The text a mark covers, from PaperShelfCore, which is also what the MCP server
    /// reads so that both see the same thing.
    private func quotedText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        PaperShelfCore.quotedText(of: annotation, on: page)
    }

    /// The selection is the only exact source for a mark just being made. Its union box
    /// also covers the ragged space before wrapped lines, which is why reading that box
    /// put words the reader did not highlight into the Notes rail.
    private func selectedText(in selection: PDFSelection, on page: PDFPage) -> String {
        selection.selectionsByLine()
            .filter { $0.pages.contains(page) }
            .compactMap(\.string)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
        guard let view, let document = view.document, let selection = view.currentSelection else { return 0 }
        var madeMarks: [Mark] = []

        for page in selection.pages {
            let lines = selection.selectionsByLine()
                .filter { $0.pages.contains(page) }
                .map { $0.bounds(for: page) }
                .filter { $0.width > 0 && $0.height > 0 }
            guard !lines.isEmpty else { continue }

            let union = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
            let mark = PDFAnnotation(bounds: union, forType: .highlight, withProperties: nil)
            mark.color = colour
            mark.modificationDate = Date()
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
            madeMarks.append(Mark(page: document.index(for: page) + 1, kind: "Highlight",
                                  quoted: selectedText(in: selection, on: page),
                                  note: mark.contents ?? "", colour: colour,
                                  annotation: mark))
        }

        guard !madeMarks.isEmpty else { return 0 }
        let wasScanning = scan != nil
        scan?.cancel()
        marks.append(contentsOf: madeMarks)
        marks.sort(by: Annotator.precedes)
        if wasScanning { startScanningForMarks() }
        save()
        view.clearSelection()
        hasSelection = false
        // Adding an annotation does not require PDFView to lay out every page again.
        view.setNeedsDisplay(view.bounds)
        selectedMark = madeMarks.last?.id
        return madeMarks.count
    }

    /// Repaints an existing mark.
    func setColour(_ colour: NSColor, on mark: Mark) {
        mark.annotation.color = colour
        mark.annotation.modificationDate = Date()
        save()
        replace(mark, colour: colour, timestamp: mark.annotation.modificationDate)
        rescanIfNeeded()
        if let view { view.setNeedsDisplay(view.bounds) }
    }

    func remove(_ mark: Mark) {
        mark.annotation.page?.removeAnnotation(mark.annotation)
        if selectedMark == mark.id { selectedMark = nil }
        marks.removeAll { $0.id == mark.id }
        save()
        rescanIfNeeded()
        if let view { view.setNeedsDisplay(view.bounds) }
    }

    /// Clears every mark from the document. Destructive and not undoable, so the caller
    /// asks first.
    func removeAll() {
        guard let document = view?.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where Annotator.markTypes.contains(annotation.type ?? "Note") {
                page.removeAnnotation(annotation)
            }
        }
        selectedMark = nil
        scan?.cancel()
        scan = nil
        marks.removeAll()
        save()
        if let view { view.setNeedsDisplay(view.bounds) }
    }

    /// Rewrites the note on an existing mark.
    func setNote(_ text: String, on mark: Mark) {
        mark.annotation.contents = text
        mark.annotation.modificationDate = Date()
        save()
        replace(mark, note: text, timestamp: mark.annotation.modificationDate)
        rescanIfNeeded()
    }

    /// The mark under a point in the preview, if there is one.
    ///
    /// The point arrives from SwiftUI, which measures from the top, and `PDFView` is an
    /// ordinary AppKit view measuring from the bottom -- the same flip `selectionChanged`
    /// makes in the other direction.
    func mark(atViewPoint point: CGPoint) -> Mark? {
        guard let view else { return nil }
        let inView = CGPoint(x: point.x, y: view.bounds.height - point.y)
        guard let page = view.page(for: inView, nearest: false) else { return nil }
        let onPage = view.convert(inView, to: page)
        // Last rather than first: marks overlap where a passage was marked twice, and the
        // one drawn on top is the one being pointed at.
        return marks.last { $0.annotation.page === page && $0.annotation.bounds.contains(onPage) }
    }

    /// Where a mark sits in the preview, in the same top-down space as `selectionRect`,
    /// so a bar can be put against it the way one is put against a selection.
    func rect(of mark: Mark) -> CGRect? {
        guard let view, let page = mark.annotation.page else { return nil }
        let box = view.convert(mark.annotation.bounds, from: page)
        return CGRect(x: box.minX, y: view.bounds.height - box.maxY,
                      width: box.width, height: box.height)
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
        let sidecar = notesSidecarText(for: url)
        unsaved = false
        let previous = writeTask
        writeTask = Task { [weak self] in
            _ = await previous?.value
            let failure = await Annotator.persist(data, to: url, sidecar: sidecar)
            guard let self else { return }
            self.lastError = failure
            if failure == nil { self.notesSidecarDate = self.sidecarDate(for: url) }
        }
    }

    var notesSidecarIsCurrent: Bool {
        guard Prefs.shared.syncNotesSidecar, let url, let notesSidecarDate else { return false }
        let pdfDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantFuture
        return notesSidecarDate >= pdfDate
    }

    private func sidecarDate(for url: URL) -> Date? {
        try? notesSidecarURL(for: url).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private func notesSidecarText(for url: URL) -> String? {
        guard Prefs.shared.syncNotesSidecar else { return nil }
        let title = statedTitle?.isEmpty == false
            ? statedTitle! : url.deletingPathExtension().lastPathComponent
        let scope = HighlightMeaningScope.forDocument(url, id: documentID)
        let exports = marks.map {
            MarkExport(page: $0.page, quoted: $0.quoted, note: $0.note,
                       meaning: Palette.shared.meaning(for: $0.colour, scope: scope),
                       colour: colourHex($0.colour), timestamp: $0.timestamp)
        }
        return markdownNotes(title: title, source: url.path, marks: exports)
    }

    private func colourHex(_ colour: NSColor) -> String {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X",
                      Int((max(0, min(1, rgb.redComponent)) * 255).rounded()),
                      Int((max(0, min(1, rgb.greenComponent)) * 255).rounded()),
                      Int((max(0, min(1, rgb.blueComponent)) * 255).rounded()))
    }

    private func replace(_ mark: Mark, colour: NSColor? = nil, note: String? = nil,
                         timestamp: Date? = nil) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }) else { return }
        let current = marks[index]
        marks[index] = Mark(id: current.id, page: current.page, kind: current.kind,
                            quoted: current.quoted, note: note ?? current.note,
                            colour: colour ?? current.colour,
                            timestamp: timestamp ?? current.timestamp,
                            annotation: current.annotation)
    }

    /// Writing through a temporary file means an interrupted save cannot leave a
    /// half-written document where the original was.
    private nonisolated static func persist(_ data: Data, to url: URL,
                                            sidecar: String?) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".papershelf-notes-\(UUID().uuidString).pdf")
            var temporarySidecar: URL?
            func replaceOrMove(_ temporary: URL, at destination: URL) throws {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            }
            do {
                try data.write(to: temporary, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                if let sidecar {
                    let destination = notesSidecarURL(for: url)
                    let sidecarFile = destination.deletingLastPathComponent()
                        .appendingPathComponent(".papershelf-notes-\(UUID().uuidString).md")
                    temporarySidecar = sidecarFile
                    try sidecar.write(to: sidecarFile, atomically: true, encoding: .utf8)
                    try replaceOrMove(sidecarFile, at: destination)
                    temporarySidecar = nil
                }
                return nil
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if let temporarySidecar { try? FileManager.default.removeItem(at: temporarySidecar) }
                return error.localizedDescription
            }
        }.value
    }
}
