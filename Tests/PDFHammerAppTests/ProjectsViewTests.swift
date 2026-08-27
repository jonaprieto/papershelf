import XCTest
import PDFHammerCore
@testable import PDFHammer

/// The reading-projects view models, driven entirely through a stubbed
/// `ProjectsEnvironment`: no database, no network. That is the whole point of the
/// environment being a bag of closures rather than a call straight into `Library`.
@MainActor
final class ProjectsEnvironmentStub {
    struct Failure: Error {}

    /// Every document either available to add or already filed somewhere, keyed by
    /// content hash, so `setSection` can find a not-yet-a-member document and add it —
    /// the same "add or refile" upsert `Library.setSection` itself does.
    var catalog: [String: ProjectMember] = [:]
    var projects: [ProjectSummary] = []
    var membersByProject: [Int64: [ProjectMember]] = [:]
    var availableByProject: [Int64: [ProjectMember]] = [:]
    var tagsByHash: [String: [String]] = [:]
    var shouldThrow = false

    private(set) var membersCallCount = 0
    private(set) var sectionsCallCount = 0
    private(set) var setSectionCalls: [(id: Int64, hash: String, section: String?)] = []
    private(set) var removeMemberCalls: [(id: Int64, hash: String)] = []
    private(set) var addTagCalls: [(hash: String, name: String)] = []

    func environment() -> ProjectsEnvironment {
        ProjectsEnvironment(
            listProjects: { self.projects },
            createProject: { name in
                if self.shouldThrow { throw Failure() }
                let summary = ProjectSummary(id: Int64(self.projects.count + 1), name: name, documentCount: 0)
                self.projects.append(summary)
                return summary
            },
            deleteProject: { id in
                if self.shouldThrow { throw Failure() }
                self.projects.removeAll { $0.id == id }
            },
            members: { id in
                self.membersCallCount += 1
                if self.shouldThrow { throw Failure() }
                return self.membersByProject[id] ?? []
            },
            availableDocuments: { id in self.availableByProject[id] ?? [] },
            // Mirrors `Library.sections(ofProject:)`: the distinct sections actually in
            // use, derived from the members themselves rather than tracked separately, so
            // a stub can't drift out of sync with the members it just changed.
            sections: { id in
                self.sectionsCallCount += 1
                let names = Set((self.membersByProject[id] ?? []).compactMap(\.section))
                return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            },
            setSection: { id, hash, section in
                self.setSectionCalls.append((id, hash, section))
                if self.shouldThrow { throw Failure() }
                var members = self.membersByProject[id] ?? []
                if let index = members.firstIndex(where: { $0.document.contentHash == hash }) {
                    members[index].section = section
                } else if let entry = self.catalog[hash] {
                    var added = entry
                    added.section = section
                    members.append(added)
                }
                self.membersByProject[id] = members
            },
            removeMember: { id, hash in
                self.removeMemberCalls.append((id, hash))
                if self.shouldThrow { throw Failure() }
                self.membersByProject[id]?.removeAll { $0.document.contentHash == hash }
            },
            tags: { hash in self.tagsByHash[hash] ?? [] },
            addTag: { hash, name in
                self.addTagCalls.append((hash, name))
                if self.shouldThrow { throw Failure() }
                self.tagsByHash[hash, default: []].append(name)
            },
            removeTag: { hash, name in
                if self.shouldThrow { throw Failure() }
                self.tagsByHash[hash]?.removeAll { $0 == name }
            },
            rankedDocuments: { _, hashes in hashes },
            ask: { _, _ in "" },
            endpoint: { "https://api.openai.com/v1" },
            openAtPage: { _, _ in }
        )
    }
}

@MainActor
private func makeMember(_ hash: String, title: String = "Untitled", author: String? = nil,
                        pageCount: Int? = nil, section: String? = nil) -> ProjectMember {
    ProjectMember(document: ProjectDocument(contentHash: hash, title: title, markdown: ""),
                 author: author, pageCount: pageCount, section: section)
}

// MARK: - ProjectDetailModel: loading

@MainActor
final class ProjectDetailModelLoadTests: XCTestCase {

    func testLoadPopulatesMembersSectionsAndTags() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a", section: "background"), makeMember("b")]
        stub.tagsByHash["a"] = ["math"]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 2),
                                       env: stub.environment())

        await model.load()

        XCTAssertEqual(model.members.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(model.knownSections, ["background"])
        XCTAssertEqual(model.tagsByDocument["a"], ["math"])
        XCTAssertEqual(model.tagsByDocument["b"], [])
    }

    func testLoadSurfacesAnErrorFromTheEnvironment() async {
        let stub = ProjectsEnvironmentStub()
        stub.shouldThrow = true
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 0),
                                       env: stub.environment())

        await model.load()

        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.members.isEmpty)
    }
}

// MARK: - ProjectDetailModel: grouping

@MainActor
final class ProjectDetailModelGroupingTests: XCTestCase {

    func testGroupedMembersOrdersNamedSectionsBeforeUnfiled() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [
            makeMember("c", title: "Unfiled paper"),
            makeMember("a", title: "Background paper", section: "background"),
            makeMember("b", title: "To-read paper", section: "to read"),
        ]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 3),
                                       env: stub.environment())
        await model.load()

        let groups = model.groupedMembers
        XCTAssertEqual(groups.map(\.section), ["background", "to read", nil],
                       "named sections, alphabetically, then the unfiled group last")
        XCTAssertEqual(groups[0].members.map(\.id), ["a"])
        XCTAssertEqual(groups[1].members.map(\.id), ["b"])
        XCTAssertEqual(groups[2].members.map(\.id), ["c"])
    }

    /// A member whose section is not in `knownSections` — stale data, or a caller that
    /// only updated one of the two — must still be shown, not silently dropped from every
    /// group. Exercised directly against `groupMembers`, since a real environment (and
    /// this file's own stub) never actually produces that inconsistency on its own.
    func testAMemberInAnUnknownSectionStillGetsItsOwnGroup() {
        let groups = groupMembers([makeMember("a", section: "orphan")], knownSections: ["background"])
        XCTAssertEqual(groups.flatMap { $0.members.map(\.id) }, ["a"],
                       "an orphaned section must still produce a group, not drop its member")
    }

    func testGroupedMembersIsEmptyWithNoMembers() async {
        let stub = ProjectsEnvironmentStub()
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 0),
                                       env: stub.environment())
        await model.load()
        XCTAssertTrue(model.groupedMembers.isEmpty)
    }
}

// MARK: - ProjectDetailModel: adding documents

@MainActor
final class ProjectDetailModelAddingTests: XCTestCase {

    func testAddBatchFilesEveryDocumentUnderTheChosenSectionAndReloads() async {
        let stub = ProjectsEnvironmentStub()
        let x = makeMember("x", title: "X")
        let y = makeMember("y", title: "Y")
        stub.catalog = ["x": x, "y": y]
        stub.availableByProject[1] = [x, y]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 0),
                                       env: stub.environment())
        await model.loadAvailable()

        await model.addBatch(["x", "y"], section: "to read")

        XCTAssertEqual(Set(stub.setSectionCalls.map(\.hash)), ["x", "y"])
        XCTAssertTrue(stub.setSectionCalls.allSatisfy { $0.section == "to read" })
        XCTAssertEqual(Set(model.members.map(\.id)), ["x", "y"])
        XCTAssertTrue(model.members.allSatisfy { $0.section == "to read" })
        XCTAssertTrue(model.available.isEmpty, "documents just added must drop out of the add sheet's own list")
        XCTAssertTrue(model.knownSections.contains("to read"),
                     "a section introduced by this add must show up once reloaded")
    }

    func testAddBatchWithNoSectionFilesUnderNothing() async {
        let stub = ProjectsEnvironmentStub()
        let x = makeMember("x")
        stub.catalog = ["x": x]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 0),
                                       env: stub.environment())

        await model.addBatch(["x"], section: nil)

        XCTAssertEqual(model.members.first?.section, nil)
    }

    func testAddBatchWithNothingSelectedDoesNothing() async {
        let stub = ProjectsEnvironmentStub()
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 0),
                                       env: stub.environment())

        await model.addBatch([], section: "anything")

        XCTAssertTrue(stub.setSectionCalls.isEmpty)
        XCTAssertEqual(stub.membersCallCount, 0, "an empty batch must not even reload")
    }

    func testAddBatchSurfacesAnError() async {
        let stub = ProjectsEnvironmentStub()
        stub.catalog = ["x": makeMember("x")]
        stub.shouldThrow = true
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 0),
                                       env: stub.environment())

        await model.addBatch(["x"], section: "to read")

        XCTAssertNotNil(model.error)
    }
}

// MARK: - ProjectDetailModel: moving and removing

@MainActor
final class ProjectDetailModelMutationTests: XCTestCase {

    func testMoveRefilesADocumentWithoutReloadingAllMembers() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a")]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()
        let callsAfterLoad = stub.membersCallCount

        await model.move(model.members[0], to: "background")

        XCTAssertEqual(model.members.first?.section, "background")
        XCTAssertEqual(stub.membersCallCount, callsAfterLoad,
                       "moving a document must not re-fetch the whole member list")
        XCTAssertEqual(model.knownSections, ["background"])
    }

    func testMoveToNilFilesUnderNothing() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a", section: "background")]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()

        await model.move(model.members[0], to: nil)

        XCTAssertNil(model.members.first?.section)
    }

    func testRemoveDropsTheMemberAndRefreshesKnownSections() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a", section: "background")]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()

        await model.remove(model.members[0])

        XCTAssertTrue(model.members.isEmpty)
        XCTAssertTrue(model.knownSections.isEmpty,
                     "\"background\" had exactly one member; removing it should leave no known sections")
    }

    func testRemoveOnFailureLeavesTheMemberInPlace() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a")]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()
        stub.shouldThrow = true

        await model.remove(model.members[0])

        XCTAssertEqual(model.members.count, 1)
        XCTAssertNotNil(model.error)
    }
}

// MARK: - ProjectDetailModel: tags

@MainActor
final class ProjectDetailModelTagTests: XCTestCase {

    func testAddTagIgnoresBlankNames() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a")]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()

        await model.addTag("   ", to: model.members[0])

        XCTAssertTrue(stub.addTagCalls.isEmpty)
    }

    func testAddTagIgnoresADuplicateAlreadyOnTheDocument() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a")]
        stub.tagsByHash["a"] = ["math"]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()

        await model.addTag("math", to: model.members[0])

        XCTAssertTrue(stub.addTagCalls.isEmpty)
    }

    func testAddTagTrimsAndRecordsANewTag() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a")]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()

        await model.addTag("  math  ", to: model.members[0])

        XCTAssertEqual(stub.addTagCalls.first?.name, "math")
        XCTAssertEqual(model.tagsByDocument["a"], ["math"])
    }

    func testRemoveTagUpdatesLocalState() async {
        let stub = ProjectsEnvironmentStub()
        stub.membersByProject[1] = [makeMember("a")]
        stub.tagsByHash["a"] = ["math", "cs"]
        let model = ProjectDetailModel(project: ProjectSummary(id: 1, name: "P", documentCount: 1),
                                       env: stub.environment())
        await model.load()

        await model.removeTag("math", from: model.members[0])

        XCTAssertEqual(model.tagsByDocument["a"], ["cs"])
    }
}

// MARK: - ProjectsStore

@MainActor
final class ProjectsStoreTests: XCTestCase {

    func testLoadPopulatesProjects() async {
        let stub = ProjectsEnvironmentStub()
        stub.projects = [ProjectSummary(id: 1, name: "Thesis", documentCount: 3)]
        let store = ProjectsStore(env: stub.environment())

        await store.load()

        XCTAssertEqual(store.projects.map(\.name), ["Thesis"])
    }

    func testCreateIgnoresABlankName() async {
        let stub = ProjectsEnvironmentStub()
        let store = ProjectsStore(env: stub.environment())

        await store.create(name: "   ")

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(stub.projects.isEmpty)
    }

    func testCreateTrimsTheNameBeforeSendingIt() async {
        let stub = ProjectsEnvironmentStub()
        let store = ProjectsStore(env: stub.environment())

        await store.create(name: "  Thesis  ")

        XCTAssertEqual(stub.projects.first?.name, "Thesis")
        XCTAssertEqual(store.projects.first?.name, "Thesis")
    }

    func testCreateSurfacesAnError() async {
        let stub = ProjectsEnvironmentStub()
        stub.shouldThrow = true
        let store = ProjectsStore(env: stub.environment())

        await store.create(name: "Thesis")

        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.projects.isEmpty)
    }

    func testDeleteRemovesOnSuccess() async {
        let stub = ProjectsEnvironmentStub()
        let summary = ProjectSummary(id: 1, name: "Thesis", documentCount: 0)
        stub.projects = [summary]
        let store = ProjectsStore(env: stub.environment())
        await store.load()

        await store.delete(summary)

        XCTAssertTrue(store.projects.isEmpty)
    }

    func testDeleteLeavesTheListUnchangedOnFailure() async {
        let stub = ProjectsEnvironmentStub()
        let summary = ProjectSummary(id: 1, name: "Thesis", documentCount: 0)
        stub.projects = [summary]
        let store = ProjectsStore(env: stub.environment())
        await store.load()
        stub.shouldThrow = true

        await store.delete(summary)

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertNotNil(store.error)
    }
}

// MARK: - recognitionDetail

/// What a row shows to tell two documents apart without opening either one.
final class RecognitionDetailTests: XCTestCase {

    func testCombinesAuthorAndPageCount() {
        XCTAssertEqual(recognitionDetail(author: "Jane Doe", pageCount: 12), "Jane Doe · 12 pages")
    }

    func testSingularPageIsNotPluralised() {
        XCTAssertEqual(recognitionDetail(author: nil, pageCount: 1), "1 page")
    }

    func testNilWhenNeitherIsKnown() {
        XCTAssertNil(recognitionDetail(author: nil, pageCount: nil))
    }

    func testAnEmptyAuthorStringIsTreatedAsMissing() {
        XCTAssertEqual(recognitionDetail(author: "", pageCount: 5), "5 pages")
    }

    func testAuthorAloneWithNoPageCount() {
        XCTAssertEqual(recognitionDetail(author: "Jane Doe", pageCount: nil), "Jane Doe")
    }
}
