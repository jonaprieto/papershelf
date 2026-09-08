import XCTest
import PDFKit
@testable import PaperShelf
@testable import PaperShelfCore

@MainActor
final class AppliedTrashTests: XCTestCase {
    override class func setUp() {
        if getenv("PAPERSHELF_LIBRARY_PATH") == nil {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("trash-tests-\(UUID().uuidString).sqlite")
            setenv("PAPERSHELF_LIBRARY_PATH", path.path, 1)
        }
    }

    private func report(_ name: String, root: URL, status: Status, carriedOut: Bool) -> Item {
        Item(root: root, source: root.appendingPathComponent(name),
             destination: root.appendingPathComponent("Trash/" + name),
             status: status, carriedOut: carriedOut)
    }

    func testFinishedTrashDisappearsWhileFailuresAndPreviewsStay() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let removed = report("removed.pdf", root: root, status: .trashed, carriedOut: true)
        let preview = report("preview.pdf", root: root, status: .trashed, carriedOut: false)
        let failed = report("failed.pdf", root: root, status: .failed, carriedOut: false)
        let runner = Runner()
        let detached = expectation(forNotification: .readingFileRemoved, object: removed.source)
        runner.markForDeletion(removed)
        let out = [removed, preview, failed]
        runner.finish(out, keepingDecisions: true, derived: Runner.derive(out), syncLibrary: false)

        XCTAssertEqual(runner.results.map(\.key), [preview.key, failed.key])
        XCTAssertNil(runner.item(removed.key))
        XCTAssertTrue(runner.ancestors(of: removed.key).isEmpty)
        XCTAssertEqual(runner.statusCounts.first { $0.0 == .trashed }?.1, 1)
        XCTAssertEqual(runner.deletedCount, 0)
        XCTAssertEqual(runner.activity.done, 3)
        XCTAssertFalse(runner.busy)
        await fulfillment(of: [detached], timeout: 1)
    }

    func testLibraryForgetsTrashWithoutRemovingOtherCopiesOrFailedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(url: root.appendingPathComponent("library.sqlite"))
        let removed = report("removed.pdf", root: root, status: .trashed, carriedOut: true)
        let failed = report("failed.pdf", root: root, status: .failed, carriedOut: false)
        let preview = report("preview.pdf", root: root, status: .trashed, carriedOut: false)
        let record = try await library.indexDocument(path: removed.key, contentHash: "shared")
        let copy = root.appendingPathComponent("copy.pdf").path
        try await library.recordLocation(copy, forDocument: record.id)
        try await library.addTag("keep", toDocument: record.id)
        _ = try await library.indexDocument(path: failed.key, contentHash: nil)
        let runner = Runner()
        await runner.syncLibrary(with: [removed, failed, preview], library: library)

        let old = try await library.document(atPath: removed.key)
        let trash = try await library.document(atPath: removed.currentURL.path)
        let kept = try await library.document(atPath: copy)
        let failedRecord = try await library.document(atPath: failed.key)
        let previewRecord = try await library.document(atPath: preview.key)
        let tags = try await library.tags(forDocument: record.id)
        XCTAssertNil(old)
        XCTAssertNil(trash)
        XCTAssertEqual(kept?.id, record.id)
        XCTAssertNotNil(failedRecord)
        XCTAssertNotNil(previewRecord)
        XCTAssertEqual(tags.map(\.name), ["keep"])
    }

    func testReaderFailureStopsBothApplyPathsBeforeTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("keep.pdf")
        try makeTextPDF(at: url, text: "Keep this paper")
        let view = PDFView()
        view.document = try XCTUnwrap(PDFDocument(url: url))
        let reader = Annotator()
        reader.attach(view, url: url)
        defer { reader.detach() }
        reader.reportOpenFailure(url)

        for batch in [false, true] {
            let runner = Runner()
            runner.includeReadingFile(url)
            let item = try XCTUnwrap(runner.results.first)
            runner.markForDeletion(item)
            let options = Options(passwords: [], recursive: false, dryRun: false)
            if batch { await runner.apply(options: options) }
            else { await runner.applyNow(item, as: item.destinationName, options: options) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(runner.item(item.key))
            XCTAssertEqual(runner.deletedCount, 1)
            XCTAssertEqual(runner.appliedCount, 0)
            XCTAssertFalse(runner.busy)
        }
    }
}
