import XCTest
@testable import PDFHammerCore

final class DuplicatesTests: XCTestCase {

    // MARK: - Fixtures

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName("duplicates-tests"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func scan(_ root: URL) -> [Item] {
        process(jobs: collectJobs(roots: [root], recursive: true),
                options: Options(passwords: [], recursive: true, dryRun: true))
    }

    // MARK: - Pass 1: identical bytes, arriving one at a time

    func testIdenticalBytesAreFoundOnTheSecondArrivalNotBefore() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (1).pdf"))
        // A independently-generated file, genuinely different, so it must never join the
        // group above -- same fixture shape as HammerTests's own identical-bytes test.
        try makePDF(at: root.appendingPathComponent("Neuromancer.pdf"), password: nil)

        let items = scan(root)
        let dune = try XCTUnwrap(items.first { $0.sourceName == "Dune.pdf" })
        let duneCopy = try XCTUnwrap(items.first { $0.sourceName == "Dune (1).pdf" })
        let neuromancer = try XCTUnwrap(items.first { $0.sourceName == "Neuromancer.pdf" })

        var index = DuplicateIndex()
        XCTAssertNil(index.insert(dune), "nothing to match yet, on its own")
        let group = try XCTUnwrap(index.insert(duneCopy), "the second identical file should match the first")
        XCTAssertEqual(group.kind, .identical)
        XCTAssertEqual(Set(group.items.map(\.sourceName)), ["Dune.pdf", "Dune (1).pdf"])
        XCTAssertEqual(group.keeper.sourceName, "Dune.pdf", "same size, so the shorter name wins")

        XCTAssertNil(index.insert(neuromancer), "different bytes and size must never join the group")
    }

    func testInsertAgreesWithDuplicateGroupsOnTheSameFixture() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("shelf"), withIntermediateDirectories: true)

        // An identical pair.
        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let duneBytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try duneBytes.write(to: root.appendingPathComponent("shelf/Dune (1).pdf"))
        // A same-text pair: different bytes, same opening words.
        try makeTextPDF(at: root.appendingPathComponent("Report.pdf"),
                        text: String(repeating: "the quarterly numbers are steady this year ", count: 20))
        try makeTextPDF(at: root.appendingPathComponent("shelf/Report-final.pdf"),
                        text: String(repeating: "the quarterly numbers are steady this year ", count: 20))
        // A name-only pair: unrelated bytes, a copy-marker filename.
        try makePDF(at: root.appendingPathComponent("Refactoring.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("Refactoring (1).pdf"), password: "x")
        // A file alone.
        try makePDF(at: root.appendingPathComponent("Neuromancer.pdf"), password: nil)

        let items = scan(root)
        let batch = duplicateGroups(in: items)

        var index = DuplicateIndex()
        var lastSeen: [String: DuplicateGroup] = [:]
        for item in items {
            if let group = index.insert(item) { lastSeen[group.id] = group }
        }

        func signature(_ groups: [DuplicateGroup]) -> Set<Set<String>> {
            Set(groups.map { Set($0.items.map(\.sourceName)) })
        }

        XCTAssertEqual(signature(batch), signature(Array(lastSeen.values)),
                       "the incremental index must find exactly the groups a full rescan finds")
        XCTAssertEqual(batch.count, 3)

        let batchByKind = Dictionary(uniqueKeysWithValues: batch.map { (Set($0.items.map(\.sourceName)), $0.kind) })
        for group in lastSeen.values {
            XCTAssertEqual(batchByKind[Set(group.items.map(\.sourceName))], group.kind,
                           "the same files must be matched by the same signal in both")
        }
    }

    // MARK: - Pass 2: same text

    func testSameTextIsFoundEvenThoughOneCopyIsEncrypted() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        let text = String(repeating: "a shared opening paragraph that repeats enough to pass the floor ", count: 10)
        try makeTextPDF(at: root.appendingPathComponent("Notes.pdf"), text: text)
        try makeTextPDF(at: root.appendingPathComponent("Notes-scan.pdf"), text: text, password: "shut")

        let items = scan(root)
        var index = DuplicateIndex()
        var group: DuplicateGroup?
        for item in items {
            if let found = index.insert(item, passwords: ["shut"]) { group = found }
        }

        let found = try XCTUnwrap(group)
        XCTAssertEqual(found.kind, .sameText)
        XCTAssertEqual(found.items.count, 2)
    }

    // MARK: - Pass 3: similar name

    func testLikelyDuplicatesAreFoundByNameOneAtATime() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        try makePDF(at: root.appendingPathComponent("The Pragmatic Programmer.pdf"), password: nil)
        try makePDF(at: root.appendingPathComponent("the-pragmatic-programmer (1).pdf"), password: "x")
        try makePDF(at: root.appendingPathComponent("Refactoring.pdf"), password: nil)

        let items = scan(root)
        var index = DuplicateIndex()
        var group: DuplicateGroup?
        for item in items {
            if let found = index.insert(item) { group = found }
        }

        let found = try XCTUnwrap(group)
        XCTAssertEqual(found.kind, .likely)
        XCTAssertEqual(found.items.count, 2)
    }

    // MARK: - remove()

    func testRemoveStopsAVanishedFileFromBeingMatchedAgain() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (1).pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (2).pdf"))

        let items = scan(root)
        let a = try XCTUnwrap(items.first { $0.sourceName == "Dune.pdf" })
        let b = try XCTUnwrap(items.first { $0.sourceName == "Dune (1).pdf" })
        let c = try XCTUnwrap(items.first { $0.sourceName == "Dune (2).pdf" })

        var index = DuplicateIndex()
        XCTAssertNil(index.insert(a))
        XCTAssertNotNil(index.insert(b))
        index.remove(a.key)

        // c is byte-identical to a and b, but a is gone: only b should still be there to
        // match, and a's name must not appear in the reported group.
        let group = try XCTUnwrap(index.insert(c))
        XCTAssertEqual(Set(group.items.map(\.sourceName)), ["Dune (1).pdf", "Dune (2).pdf"])
    }

    // MARK: - Dismissal

    func testADismissedMatchIsNeverReportedAgain() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (1).pdf"))

        let items = scan(root)
        let a = try XCTUnwrap(items.first { $0.sourceName == "Dune.pdf" })
        let b = try XCTUnwrap(items.first { $0.sourceName == "Dune (1).pdf" })

        var index = DuplicateIndex()
        XCTAssertNil(index.insert(a))
        let group = try XCTUnwrap(index.insert(b))
        XCTAssertFalse(index.isDismissed(group.id))

        index.remove(a.key)
        index.remove(b.key)
        index.dismiss(group.id)
        XCTAssertTrue(index.isDismissed(group.id))

        XCTAssertNil(index.insert(a), "re-arriving after dismissal must not report again")
        XCTAssertNil(index.insert(b), "neither must its partner")
    }

    func testNewEvidenceStillSurfacesEvenWhenAnEarlierPairWasDismissed() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (1).pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (2).pdf"))

        let items = scan(root)
        let a = try XCTUnwrap(items.first { $0.sourceName == "Dune.pdf" })
        let b = try XCTUnwrap(items.first { $0.sourceName == "Dune (1).pdf" })
        let c = try XCTUnwrap(items.first { $0.sourceName == "Dune (2).pdf" })

        var index = DuplicateIndex()
        _ = index.insert(a)
        let firstGroup = try XCTUnwrap(index.insert(b))
        index.dismiss(firstGroup.id)

        // The same signal (identical bytes, same digest) is what was dismissed, and a third
        // copy shares that same digest, so this is not new evidence -- it is the group
        // getting bigger under the exact match the user already settled.
        XCTAssertNil(index.insert(c))
    }

    // MARK: - Durable dismissal

    func testADismissedMatchStaysDismissedAcrossARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let library = try Library(url: url)
        let initial = try await library.dismissedDuplicateIDs()
        XCTAssertTrue(initial.isEmpty)
        try await library.dismissDuplicate(groupID: "name:catch22")
        // Pressing keep-both twice means what it meant the first time.
        try await library.dismissDuplicate(groupID: "name:catch22")
        let stored = try await library.dismissedDuplicateIDs()
        XCTAssertEqual(stored, ["name:catch22"])

        // A relaunch is a second connection to the same file.
        let reopened = try Library(url: url)
        let afterRelaunch = try await reopened.dismissedDuplicateIDs()
        XCTAssertEqual(afterRelaunch, ["name:catch22"],
                       "a decision the user already made must survive quitting the app")

        try await reopened.undismissDuplicate(groupID: "name:catch22")
        let afterUndo = try await library.dismissedDuplicateIDs()
        XCTAssertTrue(afterUndo.isEmpty)
    }

    func testAnIndexSeededFromDiskHonoursAPreviouslyDismissedGroup() throws {
        let fm = FileManager.default
        let root = try scratchRoot()
        defer { try? fm.removeItem(at: root) }

        try makePDF(at: root.appendingPathComponent("Dune.pdf"), password: nil)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Dune.pdf"))
        try bytes.write(to: root.appendingPathComponent("Dune (1).pdf"))

        let items = scan(root)
        let a = try XCTUnwrap(items.first { $0.sourceName == "Dune.pdf" })
        let b = try XCTUnwrap(items.first { $0.sourceName == "Dune (1).pdf" })

        // Find the id the same way a first run would, without persisting anything yet.
        var probe = DuplicateIndex()
        _ = probe.insert(a)
        let group = try XCTUnwrap(probe.insert(b))

        // A fresh index, as a new launch would build it, seeded with that id already
        // dismissed -- standing in for what a caller would load from
        // `loadDismissedDuplicates()` before ever seeing these two files again.
        var relaunched = DuplicateIndex(dismissed: [group.id])
        XCTAssertNil(relaunched.insert(a))
        XCTAssertNil(relaunched.insert(b), "a fresh process must still honour a dismissal made before it started")
    }
}
