import XCTest
import PDFKit
@testable import PaperShelfCore
@testable import PaperShelf

/// A password put on the paper being read, or typed to open one, is held for the run and
/// never written to a preferences file.
@MainActor
final class PDFPasswordTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func reader(_ annotator: Annotator) throws -> PDFView {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.document = try XCTUnwrap(PDFDocument(url: scratch))
        annotator.attach(view, url: scratch)
        return view
    }

    func testThePaperOnScreenIsLockedAndOpenedAgain() async throws {
        try makeTextPDF(at: scratch, text: "Alpha")
        let annotator = Annotator()
        let view = try reader(annotator)
        defer { annotator.detach(); _ = view }
        let password = "lock-\(UUID().uuidString)"

        let locking = await annotator.changePassword(to: password)
        XCTAssertNil(locking)
        let locked = try XCTUnwrap(PDFDocument(url: scratch))
        XCTAssertTrue(locked.isLocked)
        XCTAssertTrue(Prefs.shared.pdfPasswords.contains(password),
                      "the window would re-read the file it just locked and find it shut")
        XCTAssertFalse(Prefs.shared.passwords.contains(password), "the password was written down")

        let opening = await annotator.changePassword(to: nil)
        XCTAssertNil(opening)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(url: scratch)).isEncrypted)
    }

    /// PDFKit asks for a locked file's password over the page. Answering it there has to
    /// reach the annotator, which read nothing while the file was shut.
    func testAPaperUnlockedOnThePageIsReadAgain() throws {
        let password = "typed-\(UUID().uuidString)"
        try makeTextPDF(at: scratch, text: "Alpha", password: password)
        let annotator = Annotator()
        let view = try reader(annotator)
        defer { annotator.detach(); _ = view }

        XCTAssertTrue(annotator.isLocked)
        XCTAssertTrue(try XCTUnwrap(view.document).unlock(withPassword: password))
        XCTAssertFalse(annotator.isLocked, "the annotator still thinks the file is shut")
    }
}
