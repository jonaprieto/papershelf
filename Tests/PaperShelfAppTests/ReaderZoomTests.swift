import XCTest
import SwiftUI
import PDFKit
@testable import PaperShelf

@MainActor
final class ReaderZoomTests: XCTestCase {
    func testScrollingAndReaderUpdatesKeepManualZoomAndPosition() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(scratchName("reader-zoom"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: url, pages: ["First page", "Second page", "Wide page"])
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.page(at: 2)?.setBounds(CGRect(x: 0, y: 0, width: 842, height: 595), for: .mediaBox)
        let view = FitWidthPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        view.document = document
        let annotator = Annotator()
        annotator.attach(view, url: url)
        defer { annotator.detach() }
        let coordinator = PDFPreview.Coordinator(annotator: annotator)
        coordinator.wanted = url
        view.requestFit(.page)
        view.layout()
        let fitted = view.scaleFactor
        XCTAssertLessThan(fitted, 1.75)

        view.scaleFactor = 1.75
        view.go(to: PDFDestination(page: document.page(at: 1)!, at: CGPoint(x: 60, y: 420)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.scaleFactor, 1.75, accuracy: 0.002)
        let position = try XCTUnwrap(view.currentDestination)
        XCTAssertTrue(position.page === document.page(at: 1), "The test must actually scroll to the second page")
        XCTAssertLessThan(position.point.y, 792, "The test starts partway down the page")
        for appearance in [PDFReadingAppearance.normal, .sepia, .tint, .normal] {
            PDFPreview(url: url, passwords: [], annotator: annotator, fit: .page, appearance: appearance)
                .update(view, coordinator: coordinator)
            NotificationCenter.default.post(name: .PDFViewPageChanged, object: view)
            view.layout()
            XCTAssertEqual(view.scaleFactor, 1.75, accuracy: 0.002)
            XCTAssertTrue(view.currentDestination?.page === position.page)
            XCTAssertEqual(view.currentDestination?.point.y ?? 0, position.point.y, accuracy: 1)
        }
        XCTAssertEqual(annotator.customZoomPercent, 175)
        view.go(to: PDFDestination(page: document.page(at: 2)!, at: CGPoint(x: 0, y: 400)))
        view.frame.size.width = 750
        view.layout()
        XCTAssertEqual(view.scaleFactor, 1.75, accuracy: 0.002, "A wider page or resized pane must not reset manual zoom")

        var mode: PageFit = .page
        XCTAssertTrue(Command.fitPage.performPageAction(on: annotator,
            fit: Binding(get: { mode }, set: { mode = $0 })))
        view.layout()
        XCTAssertLessThan(view.scaleFactor, 1.75, "Choosing the same fit mode must still apply it")
        XCTAssertNil(annotator.customZoomPercent)
        XCTAssertFalse(view.usesCustomZoom)
    }

    func testAutomaticFitStillRespondsToResizingAndNewDocuments() throws {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        document.insert(page, at: 0)
        let view = FitWidthPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        view.document = document
        view.requestFit(.width)
        view.layout()
        let wide = view.scaleFactor
        view.frame.size.width = 650
        view.layout()
        XCTAssertLessThan(view.scaleFactor, wide)
        view.scaleFactor = 2
        view.layout()
        XCTAssertEqual(view.scaleFactor, 2, accuracy: 0.002)
        view.document = nil
        view.document = document
        view.layout()
        XCTAssertLessThan(view.scaleFactor, 2, "A newly opened document starts with the selected fit mode")
    }
}
