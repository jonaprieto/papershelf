import XCTest
import PDFKit
@testable import PaperShelf

@MainActor
final class PDFPreviewRefreshTests: XCTestCase {
    func testRewritingTheFileOnDiskShowsTheNewVersion() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("preview-refresh"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, text: "First draft")

        let view = FitWidthPDFView()
        let annotator = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        let preview = PDFPreview(url: url, passwords: [], annotator: annotator)
        preview.update(view, coordinator: coordinator)
        try await waitForText(view, "First draft")

        try rewriteFromAnotherProcess(url, text: "Second draft")
        PDFPreview.refreshIfChanged(view, coordinator: coordinator)
        try await waitForText(view, "Second draft")
    }

    /// Nothing tells the reader that a file it already has open has been written. The
    /// poll is the only thing that notices, so a test that called the refresh by hand
    /// would pass with the poll deleted.
    func testTheOpenFileIsPolledWithoutBeingAsked() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("preview-poll"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, text: "First draft")

        let view = FitWidthPDFView()
        let annotator = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        PDFPreview(url: url, passwords: [], annotator: annotator)
            .update(view, coordinator: coordinator)
        try await waitForText(view, "First draft")

        try rewriteFromAnotherProcess(url, text: "Second draft")
        try await waitForText(view, "Second draft", tries: 600)
    }

    /// The reader writes the PDF itself whenever a mark is made. That write changes the
    /// file's date as surely as another program's does, and re-reading after it would
    /// throw away the page the reader is on for a document already on screen.
    func testTheReadersOwnSaveIsNotMistakenForSomebodyElsesWrite() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("preview-own-write"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, text: "First unique paper")

        let view = FitWidthPDFView()
        let annotator = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        PDFPreview(url: url, passwords: [], annotator: annotator)
            .update(view, coordinator: coordinator)
        try await waitForText(view, "First unique paper")

        view.setCurrentSelection(view.document?.findString("First unique paper", withOptions: []).first,
                                 animate: false)
        annotator.selectionChanged()
        XCTAssertGreaterThan(annotator.highlightSelection(colour: .systemYellow), 0)
        await annotator.finishSaving()

        let shown = view.document
        PDFPreview.refreshIfChanged(view, coordinator: coordinator)
        for _ in 0..<50 where coordinator.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(view.document === shown, "Re-read the file this reader had just written")
        XCTAssertEqual(annotator.marks.count, 1)
    }

    /// Marks made a moment ago live in the view, not yet in the file. Re-reading the file
    /// then is how they are lost.
    func testMarksNotYetWrittenHoldOffTheRefresh() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("preview-unwritten"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, text: "First unique paper")

        let view = FitWidthPDFView()
        let annotator = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        PDFPreview(url: url, passwords: [], annotator: annotator)
            .update(view, coordinator: coordinator)
        try await waitForText(view, "First unique paper")

        view.setCurrentSelection(view.document?.findString("First unique paper", withOptions: []).first,
                                 animate: false)
        annotator.selectionChanged()
        XCTAssertGreaterThan(annotator.highlightSelection(colour: .systemYellow), 0)
        XCTAssertTrue(annotator.hasUnwrittenMarks)

        try makeTextPDF(at: url, text: "Second unique paper")
        let shown = view.document
        PDFPreview.refreshIfChanged(view, coordinator: coordinator)
        for _ in 0..<50 where coordinator.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(view.document === shown, "Dropped a mark that had not reached the file")
        await annotator.finishSaving()
    }

    /// A paper being rebuilt is a paper being read. The new version lands where the reader
    /// was, at the zoom the reader chose, or every recompile is a trip back to find the place.
    func testANewVersionKeepsThePageAndTheZoom() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("preview-zoom"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, pages: ["First a", "First b", "First c", "First d"])

        let view = FitWidthPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let annotator = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        PDFPreview(url: url, passwords: [], annotator: annotator)
            .update(view, coordinator: coordinator)
        try await waitForText(view, "First a")
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.scaleFactor = 2.3
        view.go(to: try XCTUnwrap(view.document?.page(at: 2)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(view.usesCustomZoom)

        let draft = folder.appendingPathComponent(scratchName("draft"))
        try makeTextPDF(at: draft, pages: ["Second a", "Second b", "Second c", "Second d"])
        try rewriteFromAnotherProcess(url, copying: draft)
        PDFPreview.refreshIfChanged(view, coordinator: coordinator)
        try await waitForText(view, "Second a")
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.scaleFactor, 2.3, accuracy: 0.002, "a rebuild threw away the reader's zoom")
        XCTAssertEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 2)
    }

    /// A mark is written when the pause after it runs out, with nobody leaving the file.
    /// The paper is still open and still being rebuilt, and having marked it once must not
    /// be what stops the page following it.
    func testAMarkAlreadyWrittenDoesNotHoldOffTheRefresh() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("preview-marked"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, text: "First unique paper")

        let view = FitWidthPDFView()
        let annotator = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        PDFPreview(url: url, passwords: [], annotator: annotator)
            .update(view, coordinator: coordinator)
        try await waitForText(view, "First unique paper")

        view.setCurrentSelection(view.document?.findString("First unique paper", withOptions: []).first,
                                 animate: false)
        annotator.selectionChanged()
        XCTAssertGreaterThan(annotator.highlightSelection(colour: .systemYellow), 0)
        for _ in 0..<300 where annotator.hasUnwrittenMarks {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(annotator.hasUnwrittenMarks, "A mark on disk still reads as waiting to be written")

        try rewriteFromAnotherProcess(url, text: "Second unique paper")
        PDFPreview.refreshIfChanged(view, coordinator: coordinator)
        try await waitForText(view, "Second unique paper")
    }

    /// Overwrites the file the way a build does: from another process, in place.
    ///
    /// Writing through `url` here would prove nothing. These tests used to, and stayed green
    /// while the reader missed every write made by anything else: a URL remembers the date
    /// it read.
    private func rewriteFromAnotherProcess(_ url: URL, text: String) throws {
        let draft = url.deletingLastPathComponent().appendingPathComponent(scratchName("draft"))
        try makeTextPDF(at: draft, text: text)
        try rewriteFromAnotherProcess(url, copying: draft)
    }

    private func rewriteFromAnotherProcess(_ url: URL, copying draft: URL) throws {
        let copy = try Process.run(URL(fileURLWithPath: "/bin/cp"), arguments: [draft.path, url.path])
        copy.waitUntilExit()
        XCTAssertEqual(copy.terminationStatus, 0)
    }

    private func waitForText(_ view: PDFView, _ text: String, tries: Int = 200) async throws {
        for _ in 0..<tries {
            if view.document?.string?.contains(text) == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected the page to read \(text)")
    }
}
