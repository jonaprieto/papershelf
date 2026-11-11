import XCTest
import PDFKit
import AppKit
@testable import PaperShelf

@MainActor
final class NoteBadgeTests: XCTestCase {

    /// A click on PDFKit's note badge reaches the reader as a click on the mark it belongs
    /// to, rather than opening PDFKit's own popup.
    func testClickingANoteBadgeIsAClickOnItsMark() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let near = PDFAnnotation(bounds: CGRect(x: 100, y: 600, width: 120, height: 14),
                                 forType: .highlight, withProperties: nil)
        near.contents = "the one clicked"
        page.addAnnotation(near)
        let far = PDFAnnotation(bounds: CGRect(x: 100, y: 400, width: 200, height: 14),
                                forType: .highlight, withProperties: nil)
        far.contents = "another"
        page.addAnnotation(far)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = FitWidthPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.document = document
        view.autoScales = false
        view.scaleFactor = 1
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let box = view.convert(near.bounds, from: page)
        let badge = try XCTUnwrap(view.documentView?.subviews.flatMap(\.subviews).first {
            $0 is NSImageView && view.convert($0.frame, from: $0.superview).minX >= box.maxX - 1
                && abs(view.convert($0.frame, from: $0.superview).minY - box.maxY) < 8
        }, "PDFKit drew no badge beside the noted mark")
        let frame = view.convert(badge.frame, from: badge.superview)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertNil(view.mark(at: centre), "the badge lies outside its mark")
        XCTAssertTrue(view.hitTest(view.convert(centre, to: view.superview)) === view)

        var clicked: CGPoint?
        view.onMarkClick = { clicked = $0 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: view.convert(centre, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let point = try XCTUnwrap(clicked)
        XCTAssertTrue(box.contains(CGPoint(x: point.x, y: view.bounds.height - point.y)))
    }
}

private extension PDFView {
    func mark(at point: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false) else { return nil }
        return page.annotation(at: convert(point, to: page))
    }
}
