import XCTest
import SwiftUI
import PDFKit
@testable import PaperShelf

/// The row under a reader's page, drawn in a real window.
@MainActor
final class ReaderBarTests: XCTestCase {

    /// Before the file's size has been read and before the document has said anything
    /// about itself, every line the bar can choose between was the bare file name, and
    /// `ViewThatFits` traps on children that share an identity. That was a crash on the
    /// first frame of every reader.
    func testTheBarDrawsBeforeAnythingIsKnownAboutTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try makeTextPDF(at: url, text: "Alpha")
        defer { try? FileManager.default.removeItem(at: url) }

        let hosting = NSHostingView(rootView: ReaderWindow(url: url).frame(width: 1400, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
    }
}
