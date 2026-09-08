import XCTest
import PDFKit
@testable import PaperShelf

@MainActor
final class PDFPreviewIdentityTests: XCTestCase {
    func testChangingDocumentsAndAnnotatorsDoesNotReuseTheOldPDF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(scratchName("preview-identity"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.pdf")
        let second = folder.appendingPathComponent("second.pdf")
        try makeTextPDF(at: first, text: "First unique paper")
        try makeTextPDF(at: second, text: "Second unique paper")
        let view = FitWidthPDFView()
        let a = Annotator(), b = Annotator()
        let coordinator = PDFPreview.Coordinator(annotator: a)
        defer { PDFPreview.dismantleNSView(view, coordinator: coordinator) }
        PDFPreview(url: first, passwords: [], annotator: a).update(view, coordinator: coordinator)
        try await waitForDocument(view, url: first)
        view.setCurrentSelection(view.document?.findString("First unique paper", withOptions: []).first, animate: false)
        a.selectionChanged()
        XCTAssertGreaterThan(a.highlightSelection(colour: .systemYellow), 0)
        PDFPreview(url: second, passwords: [], annotator: b).update(view, coordinator: coordinator)
        XCTAssertNil(view.document, "Do not display the previous paper while the new one loads")
        try await waitForDocument(view, url: second)
        await a.finishSaving()
        XCTAssertTrue(PDFDocument(url: first)?.string?.contains("First unique paper") == true)
        XCTAssertFalse(PDFDocument(url: first)?.string?.contains("Second unique paper") == true)
        XCTAssertTrue(coordinator.annotator === b)
        XCTAssertEqual(b.url, second)
        XCTAssertNil(a.view)
        PDFPreview(url: first, passwords: [], annotator: a).update(view, coordinator: coordinator)
        PDFPreview(url: second, passwords: [], annotator: b).update(view, coordinator: coordinator)
        PDFPreview(url: first, passwords: [], annotator: a).update(view, coordinator: coordinator)
        try await waitForDocument(view, url: first)
        XCTAssertTrue(view.document?.string?.contains("First unique paper") == true)
        let missing = folder.appendingPathComponent("missing.pdf")
        PDFPreview(url: missing, passwords: [], annotator: a).update(view, coordinator: coordinator)
        for _ in 0..<100 where coordinator.wanted != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(view.document)
        XCTAssertNil(a.url)
        XCTAssertNotNil(a.lastError)
    }

    private func waitForDocument(_ view: PDFView, url: URL) async throws {
        for _ in 0..<200 {
            if view.document?.documentURL == url { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(url.lastPathComponent), got \(String(describing: view.document?.documentURL))")
    }
}
