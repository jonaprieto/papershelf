import XCTest
@testable import PaperShelfCore

final class ReachableTests: XCTestCase {
    func testAFolderThatAnswersIsReachableAndOneThatIsNotThereIsNot() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let there = await reachable(root)
        XCTAssertTrue(there)
        let gone = await reachable(root.appendingPathComponent("no-such-folder"))
        XCTAssertFalse(gone)
    }

    /// The deadline is the whole point of asking this way, so it is asked of a question
    /// that does not answer. A dead network mount is what this stands for: the call does
    /// not fail, it waits, and the window cannot wait with it.
    func testAQuestionThatDoesNotAnswerInTimeIsGivenUpOn() async throws {
        let started = Date()
        let answer = await answered(within: 0.2) {
            Thread.sleep(forTimeInterval: 5)
            return true
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertFalse(answer)
        XCTAssertLessThan(waited, 2, "gave up after \(waited)s, which is the blocked call's own time")
    }

    /// And a question that does answer is not thrown away for a deadline that has not
    /// arrived: the check above passes just as well against a function that always says no.
    func testAQuestionThatAnswersInTimeIsBelieved() async throws {
        let yes = await answered(within: 5) { true }
        XCTAssertTrue(yes)
        let no = await answered(within: 5) { false }
        XCTAssertFalse(no)
    }
}

/// The library has had an escape hatch since the beginning; everything beside it in the
/// same folder did not, so a run pointed at a scratch collection still wrote its
/// diagnostics log and run cache into the folder holding the real one.
final class SupportDirectoryTests: XCTestCase {
    func testTheSupportFolderCanBePointedSomewhereElse() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("PAPERSHELF_SUPPORT_PATH", scratch.path, 1)
        defer { unsetenv("PAPERSHELF_SUPPORT_PATH") }

        XCTAssertEqual(supportDirectory()?.path, scratch.path)
        XCTAssertEqual(runCacheURL()?.deletingLastPathComponent().path, scratch.path,
                       "the run cache still lands in the real folder")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
    }

    func testAnEmptyOverrideIsNoOverride() {
        setenv("PAPERSHELF_SUPPORT_PATH", "", 1)
        defer { unsetenv("PAPERSHELF_SUPPORT_PATH") }
        XCTAssertEqual(supportDirectory()?.lastPathComponent, "PaperShelf")
    }
}
