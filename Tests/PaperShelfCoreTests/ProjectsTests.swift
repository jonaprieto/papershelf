import XCTest
@testable import PaperShelfCore

final class ProjectsPagingTests: XCTestCase {

    func testSplitsOnPageMarkers() {
        let markdown = "<!-- page:1 -->\nFirst page text.\n\n<!-- page:2 -->\nSecond page text."
        let found = pages(of: markdown)
        XCTAssertEqual(found.map(\.page), [1, 2])
        XCTAssertEqual(found[0].text, "First page text.")
        XCTAssertEqual(found[1].text, "Second page text.")
    }

    /// Text that never adopted the `<!-- page:N -->` convention is still usable: it
    /// becomes page 1 rather than being silently dropped.
    func testNoMarkersFallsBackToOnePage() {
        let found = pages(of: "Just some text with no markers at all.")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].page, 1)
        XCTAssertEqual(found[0].text, "Just some text with no markers at all.")
    }

    func testEmptyMarkdownIsNoPages() {
        XCTAssertEqual(pages(of: "").count, 0)
    }

    func testPageMarkerWithNoFollowingTextIsDropped() {
        let markdown = "<!-- page:1 -->\n\n<!-- page:2 -->\nOnly page two has text."
        let found = pages(of: markdown)
        XCTAssertEqual(found.map(\.page), [2])
    }
}

final class ProjectsChunkingTests: XCTestCase {

    func testShortPageIsOneChunk() {
        let doc = ProjectDocument(contentHash: "h1", title: "Paper",
                                  markdown: "<!-- page:1 -->\nA short page.")
        let chunks = chunk(doc, softLimit: 1_200)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].page, 1)
        XCTAssertEqual(chunks[0].body, "A short page.")
        XCTAssertEqual(chunks[0].contentHash, "h1")
        XCTAssertEqual(chunks[0].documentTitle, "Paper")
    }

    /// The load-bearing guarantee: whatever the splitting does inside a page, no chunk's
    /// body ever mixes text from two different pages.
    func testAChunkNeverSpansTwoPages() {
        let long = Array(repeating: "Paragraph of a reasonable length about the topic.", count: 40)
            .joined(separator: "\n\n")
        let markdown = "<!-- page:1 -->\n\(long)\n\n<!-- page:2 -->\n\(long)"
        let doc = ProjectDocument(contentHash: "h1", title: "Paper", markdown: markdown)
        let chunks = chunk(doc, softLimit: 200)
        XCTAssertGreaterThan(chunks.count, 2, "a page this long should split into more than one chunk")
        XCTAssertTrue(chunks.contains { $0.page == 1 })
        XCTAssertTrue(chunks.contains { $0.page == 2 })
        for c in chunks {
            XCTAssertFalse(c.body.isEmpty)
        }
    }

    func testLongPageSplitsAtParagraphBoundariesAndStaysUnderLimitWhenPossible() {
        let paragraphs = (1...5).map { "Paragraph number \($0), about sixty characters long here." }
        let markdown = "<!-- page:1 -->\n" + paragraphs.joined(separator: "\n\n")
        let doc = ProjectDocument(contentHash: "h1", title: "Paper", markdown: markdown)
        let chunks = chunk(doc, softLimit: 130)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.body.count, 130)
        }
        // Re-joining every chunk's paragraphs, in order, reproduces the original list
        // exactly: nothing was dropped, duplicated, or cut mid-paragraph.
        XCTAssertEqual(chunks.flatMap { $0.body.components(separatedBy: "\n\n") }, paragraphs)
    }

    /// A single paragraph longer than the limit still becomes its own chunk: a cut
    /// mid-sentence would be worse than one oversized, whole quotation.
    func testOversizedSingleParagraphIsKeptWhole() {
        let huge = String(repeating: "word ", count: 500)
        let markdown = "<!-- page:1 -->\n\(huge)"
        let doc = ProjectDocument(contentHash: "h1", title: "Paper", markdown: markdown)
        let chunks = chunk(doc, softLimit: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].body, huge.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testChunkingMultipleDocumentsConcatenatesInOrder() {
        let a = ProjectDocument(contentHash: "a", title: "A", markdown: "<!-- page:1 -->\nAlpha.")
        let b = ProjectDocument(contentHash: "b", title: "B", markdown: "<!-- page:1 -->\nBeta.")
        let chunks = chunk([a, b])
        XCTAssertEqual(chunks.map(\.contentHash), ["a", "b"])
    }
}

final class ProjectsSelectionTests: XCTestCase {

    func testFullRecallSkipsSearchWhenEverythingFits() async throws {
        let doc = ProjectDocument(contentHash: "h1", title: "Small Paper",
                                  markdown: "<!-- page:1 -->\nJust a little text.")
        var searchWasCalled = false
        let excerpts = try await selectExcerpts(question: "anything", documents: [doc], budget: 12_000) { _, _ in
            searchWasCalled = true
            return []
        }
        XCTAssertFalse(searchWasCalled, "a project that already fits must not trigger retrieval")
        XCTAssertEqual(excerpts.count, 1)
        XCTAssertEqual(excerpts[0].body, "Just a little text.")
    }

    func testRankedRetrievalOrdersDocumentsBySearchResult() async throws {
        let a = ProjectDocument(contentHash: "a", title: "A", markdown: "<!-- page:1 -->\n" + String(repeating: "a", count: 50))
        let b = ProjectDocument(contentHash: "b", title: "B", markdown: "<!-- page:1 -->\n" + String(repeating: "b", count: 50))
        // Budget only fits one document's worth of text, forcing ranked mode.
        let excerpts = try await selectExcerpts(question: "q", documents: [a, b], budget: 60) { _, hashes in
            XCTAssertEqual(Set(hashes), ["a", "b"])
            return ["b", "a"]   // b ranked first
        }
        XCTAssertEqual(excerpts.first?.contentHash, "b")
    }

    func testRankedRetrievalNeverExceedsBudget() async throws {
        let docs = (1...5).map {
            ProjectDocument(contentHash: "h\($0)", title: "Doc \($0)",
                            markdown: "<!-- page:1 -->\n" + String(repeating: "x", count: 500))
        }
        let excerpts = try await selectExcerpts(question: "q", documents: docs, budget: 1_000) { _, hashes in
            hashes
        }
        let total = excerpts.reduce(0) { $0 + $1.body.count }
        XCTAssertLessThanOrEqual(total, 1_000)
        XCTAssertFalse(excerpts.isEmpty)
    }

    /// A document the search does not mention is still part of the project, so it is
    /// kept, just ordered after everything the search actually ranked.
    func testDocumentsMissingFromSearchResultsAreKeptButOrderedLast() async throws {
        let a = ProjectDocument(contentHash: "a", title: "A", markdown: "<!-- page:1 -->\n" + String(repeating: "a", count: 100))
        let b = ProjectDocument(contentHash: "b", title: "B", markdown: "<!-- page:1 -->\n" + String(repeating: "b", count: 100))
        // A third, large document pushes the total over budget (forcing ranked mode)
        // without letting a+b's combined size alone decide whether both are kept.
        let c = ProjectDocument(contentHash: "c", title: "C", markdown: "<!-- page:1 -->\n" + String(repeating: "c", count: 500))
        let excerpts = try await selectExcerpts(question: "q", documents: [a, b, c], budget: 250) { _, _ in
            ["b"]   // search only mentions "b"; "a" and "c" are missing from its results
        }
        // b (ranked) first, a (unranked, budget allows it) second, c dropped: too big to
        // fit once b and a are already in.
        XCTAssertEqual(excerpts.map(\.contentHash), ["b", "a"])
    }

    func testSkipsAChunkThatWouldOverflowRatherThanTruncatingIt() async throws {
        let a = ProjectDocument(contentHash: "a", title: "A",
                                markdown: "<!-- page:1 -->\n" + String(repeating: "a", count: 90))
        let b = ProjectDocument(contentHash: "b", title: "B",
                                markdown: "<!-- page:1 -->\n" + String(repeating: "b", count: 5))
        // Budget fits "a" alone or "b" alone but not both; "a" ranks first and is skipped
        // entirely only if it doesn't fit: here it does fit within 90, and b still fits after.
        let excerpts = try await selectExcerpts(question: "q", documents: [a, b], budget: 92) { _, _ in ["a", "b"] }
        XCTAssertTrue(excerpts.contains { $0.contentHash == "a" && $0.body.count == 90 },
                     "the chunk that fits must be included whole, not cut down")
        XCTAssertFalse(excerpts.contains { $0.contentHash == "b" }, "nothing left in the budget for b")
    }
}

final class ProjectsPromptTests: XCTestCase {

    func testPromptLabelsEachExcerptWithTitleAndPage() {
        let excerpts = [
            ProjectChunk(contentHash: "a", documentTitle: "Paper One", page: 3, body: "Some text."),
        ]
        let prompt = readingProjectPrompt(question: "What is X?", projectName: "My Project", excerpts: excerpts)
        XCTAssertTrue(prompt.contains("Question: What is X?"))
        XCTAssertTrue(prompt.contains("My Project"))
        XCTAssertTrue(prompt.contains("Paper One, p. 3"))
        XCTAssertTrue(prompt.contains("Some text."))
        XCTAssertTrue(prompt.contains("1 document"))
        XCTAssertTrue(prompt.contains("1 excerpt"))
    }

    func testPromptHasAPlaceholderWhenNothingMatched() {
        let prompt = readingProjectPrompt(question: "What is X?", projectName: "Empty", excerpts: [])
        XCTAssertTrue(prompt.contains("none of the project's documents matched this question"))
    }

    func testPromptCountsDistinctDocumentsNotExcerpts() {
        let excerpts = [
            ProjectChunk(contentHash: "a", documentTitle: "A", page: 1, body: "x"),
            ProjectChunk(contentHash: "a", documentTitle: "A", page: 2, body: "y"),
        ]
        let prompt = readingProjectPrompt(question: "q", projectName: "P", excerpts: excerpts)
        XCTAssertTrue(prompt.contains("1 document"))
        XCTAssertTrue(prompt.contains("2 excerpts"))
    }
}

final class ProjectsCitationTests: XCTestCase {

    func testParsesASimpleCitation() {
        let excerpts = [ProjectChunk(contentHash: "h1", documentTitle: "Gödel, Escher, Bach", page: 42, body: "...")]
        let reply = "Strange loops are central to the argument (Gödel, Escher, Bach, p. 42)."
        let citations = parseCitations(in: reply, excerpts: excerpts)
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations[0].documentTitle, "Gödel, Escher, Bach")
        XCTAssertEqual(citations[0].page, 42)
        XCTAssertEqual(citations[0].contentHash, "h1")
    }

    func testTitleMatchingIsCaseInsensitive() {
        let excerpts = [ProjectChunk(contentHash: "h1", documentTitle: "Dune", page: 1, body: "...")]
        let citations = parseCitations(in: "As shown (dune, p. 1).", excerpts: excerpts)
        XCTAssertEqual(citations.first?.contentHash, "h1")
    }

    /// Two distinct documents can share a title (a preprint and its published version,
    /// say). The citation must resolve to whichever one actually carries the page named,
    /// not just the first excerpt whose title matches.
    func testSameTitleDifferentDocumentsResolveByPage() {
        let excerpts = [
            ProjectChunk(contentHash: "preprint", documentTitle: "Paper", page: 1, body: "first"),
            ProjectChunk(contentHash: "published", documentTitle: "Paper", page: 9, body: "ninth"),
        ]
        let reply = "First point (Paper, p. 1). Later point (Paper, p. 9)."
        let citations = parseCitations(in: reply, excerpts: excerpts)
        XCTAssertEqual(citations.map(\.page), [1, 9])
        XCTAssertEqual(citations.map(\.contentHash), ["preprint", "published"])
    }

    /// A citation naming a document never actually sent is surfaced with a nil hash
    /// rather than silently linking to whatever excerpt happens to be first.
    func testUnmatchedCitationHasNoContentHash() {
        let excerpts = [ProjectChunk(contentHash: "h1", documentTitle: "Real Paper", page: 1, body: "...")]
        let citations = parseCitations(in: "Per (Invented Paper, p. 1).", excerpts: excerpts)
        XCTAssertEqual(citations.count, 1)
        XCTAssertNil(citations[0].contentHash)
    }

    func testNoCitationsInPlainText() {
        XCTAssertTrue(parseCitations(in: "No citations here at all.", excerpts: []).isEmpty)
    }

    func testCitationRangeCoversTheParenthetical() {
        let excerpts = [ProjectChunk(contentHash: "h1", documentTitle: "P", page: 2, body: "...")]
        let reply = "See (P, p. 2) for details."
        let citations = parseCitations(in: reply, excerpts: excerpts)
        XCTAssertEqual(String(reply[citations[0].range]), "(P, p. 2)")
    }
}

final class ProjectsPrivacyPreviewTests: XCTestCase {

    func testDefaultEndpointIsRecognised() {
        let preview = outboundPreview(excerpts: [], endpoint: defaultAIEndpoint)
        XCTAssertTrue(preview.isDefaultEndpoint)
        XCTAssertFalse(preview.isPlaintext)
        XCTAssertEqual(preview.endpointHost, "api.openai.com")
    }

    func testCustomEndpointIsNotDefault() {
        let preview = outboundPreview(excerpts: [], endpoint: "https://my-llm.example.com/v1")
        XCTAssertFalse(preview.isDefaultEndpoint)
        XCTAssertEqual(preview.endpointHost, "my-llm.example.com")
    }

    /// The exact case the reviewers called out: an http endpoint must not read as safe
    /// just because it superficially resembles the default host.
    func testPlainHTTPIsFlaggedEvenOnTheSameHost() {
        let preview = outboundPreview(excerpts: [], endpoint: "http://api.openai.com/v1")
        XCTAssertFalse(preview.isDefaultEndpoint)
        XCTAssertTrue(preview.isPlaintext)
    }

    func testCountsDocumentsAndCharacters() {
        let excerpts = [
            ProjectChunk(contentHash: "a", documentTitle: "A", page: 1, body: "12345"),
            ProjectChunk(contentHash: "a", documentTitle: "A", page: 2, body: "123"),
            ProjectChunk(contentHash: "b", documentTitle: "B", page: 1, body: "1234567"),
        ]
        let preview = outboundPreview(excerpts: excerpts, endpoint: defaultAIEndpoint)
        XCTAssertEqual(preview.documentCount, 2)
        XCTAssertEqual(preview.approximateCharacterCount, 15)
    }
}
