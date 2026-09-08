import XCTest
import PDFKit
import PaperShelfCore
@testable import PaperShelf

@MainActor
final class RenameTests: XCTestCase {
    override class func setUp() {
        if getenv("PAPERSHELF_LIBRARY_PATH") == nil {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("rename-tests-\(UUID().uuidString).sqlite")
            setenv("PAPERSHELF_LIBRARY_PATH", path.path, 1)
        }
    }

    func testCurrentFileKeepsTheSelectedRootForBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = folder.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: source, text: "Preserve the backup tree")
        let job = try XCTUnwrap(collectJobs(roots: [root], recursive: true).first)
        let current = folder.appendingPathComponent("current.pdf")
        try FileManager.default.moveItem(at: source, to: current)
        let done = process(job: job.replacingFile(with: current),
                           options: Options(passwords: [], recursive: false, dryRun: false),
                           overrideName: "renamed.pdf")
        XCTAssertTrue(done.carriedOut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("original_pdfs/nested/current.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("original_pdfs").path))
    }

    func testRepeatedRenamesSaveNotesAndKeepTheCurrentFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: source, text: "A note to keep")
        let runner = Runner()
        runner.includeReadingFile(source)
        let item = try XCTUnwrap(runner.results.first)
        let view = PDFView()
        view.document = try XCTUnwrap(PDFDocument(url: source))
        let reader = Annotator()
        reader.attach(view, url: source)
        view.currentSelection = view.document?.findString("note", withOptions: []).first
        XCTAssertEqual(reader.highlightSelection(colour: .yellow), 1)
        let options = Options(passwords: [], recursive: false, dryRun: false,
                              backup: BackupSettings(enabled: false))
        let firstSucceeded = await runner.applyNow(item, as: "first.pdf", options: options)
        XCTAssertTrue(firstSucceeded)
        reader.detach()
        let first = try XCTUnwrap(runner.item(item.key))
        XCTAssertEqual(first.currentFilename, "first.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(PDFDocument(url: first.currentURL)?.page(at: 0)?.annotations.count, 1)

        runner.reopen(first)
        let secondSucceeded = await runner.applyNow(first, as: "second.pdf", options: options)
        XCTAssertTrue(secondSucceeded)
        let second = try XCTUnwrap(runner.item(item.key))
        XCTAssertEqual(second.currentFilename, "second.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.currentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.currentURL.path))
        XCTAssertEqual(PDFDocument(url: second.currentURL)?.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(runner.results.count, 1)
    }
}
