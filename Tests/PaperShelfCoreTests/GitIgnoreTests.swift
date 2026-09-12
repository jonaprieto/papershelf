import XCTest
@testable import PaperShelfCore

final class GitIgnoreTests: XCTestCase {
    func testSourceScansRespectInheritedAndNestedGitignoreRules() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String = "") throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".gitignore", """
        # Generated copies
        copies/
        *.draft.pdf
        !keep.draft.pdf
        /root-only.pdf
        papers/**/output?.pdf
        papers/[ab].pdf
        \\#notes.pdf
        \\!notes.pdf
        space\\ name.pdf\u{20}\u{20}
        contents/**
        !contents/keep.pdf
        !copies/rescue.pdf
        """)
        try write("papers/.gitignore", "!nested.draft.pdf\nlocal.pdf\n")
        try write("copies/.gitignore", "!rescue.pdf\n")
        let excluded = [
            "copies/copy.pdf", "copies/rescue.pdf", "papers/copies/copy.pdf",
            "discard.draft.pdf", "papers/discard.draft.pdf", "root-only.pdf",
            "papers/output1.pdf", "papers/deep/output2.pdf", "papers/a.pdf",
            "papers/local.pdf", "#notes.pdf", "!notes.pdf", "space name.pdf",
            "contents/drop.pdf", "papers/deep/local.pdf",
        ]
        let included = [
            "paper.pdf", "keep.draft.pdf", "papers/nested.draft.pdf",
            "papers/root-only.pdf", "papers/c.pdf", "papers/output12.pdf",
            "contents/keep.pdf",
        ]
        for path in excluded + included { try write(path) }
        func scanned(_ selections: [URL], recursive: Bool = true) -> Set<String> {
            Set(collectJobs(roots: selections, recursive: recursive).map {
                String($0.file.standardizedFileURL.path.dropFirst(root.path.count + 1))
            })
        }
        XCTAssertEqual(scanned([root]), Set(included))
        XCTAssertEqual(scanned([root], recursive: false), ["paper.pdf", "keep.draft.pdf"])
        XCTAssertEqual(scanned([root.appendingPathComponent("papers")]),
                       Set(included.filter { $0.hasPrefix("papers/") }))
        XCTAssertTrue(scanned([root.appendingPathComponent("copies")]).isEmpty)
        XCTAssertTrue(scanned([root.appendingPathComponent("copies/rescue.pdf")]).isEmpty)
        XCTAssertTrue(scanned([root.appendingPathComponent("discard.draft.pdf")]).isEmpty)
        XCTAssertEqual(scanned([root.appendingPathComponent("keep.draft.pdf")]), ["keep.draft.pdf"])
        XCTAssertEqual(scanned([root, root.appendingPathComponent("papers")]), Set(included))

        // Ignore edits take effect on the next scan, without restarting the app.
        try write(".gitignore", "paper.pdf\n")
        XCTAssertFalse(scanned([root]).contains("paper.pdf"))
        XCTAssertTrue(scanned([root]).contains("copies/copy.pdf"))
    }
}
