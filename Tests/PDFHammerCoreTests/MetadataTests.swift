import XCTest
@testable import PDFHammerCore

final class MetadataTests: XCTestCase {

    // MARK: - Stubs

    /// Matches the shape suggested in the design doc: a canned status and body, no socket
    /// ever touched. `request.url!` is safe here because it is always the URL this test
    /// built moments earlier, never anything that came off a wire.
    private func stubFetch(status: Int = 200, body: Data) -> HTTPFetch {
        { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: nil)!)
        }
    }

    private func stubFetch(status: Int = 200, json: String) -> HTTPFetch {
        stubFetch(status: status, body: Data(json.utf8))
    }

    private struct StubError: Error {}
    private func throwingFetch() -> HTTPFetch {
        { _ in throw StubError() }
    }

    /// Captures the request it was handed, so a test can inspect headers and URL without
    /// caring what body comes back.
    private final class RequestRecorder: @unchecked Sendable {
        private(set) var lastRequest: URLRequest?
        func fetch(status: Int, body: Data) -> HTTPFetch {
            { request in
                self.lastRequest = request
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                              headerFields: nil)!)
            }
        }
    }

    // MARK: - Fixtures (real shapes, captured live and trimmed to the fields these types decode)

    /// doi.org content negotiation for 10.1145/3373718.3394769, `Accept:
    /// application/vnd.citationstyles.csl+json`. Note title/container-title are scalars.
    private let cslFixture = """
    {"type":"proceedings-article",
     "title":"Coherence and normalisation-by-evaluation for bicategorical cartesian closed structure",
     "container-title":"Proceedings of the 35th Annual ACM/IEEE Symposium on Logic in Computer Science",
     "author":[{"given":"Marcelo","family":"Fiore"},{"given":"Philip","family":"Saville"}],
     "issued":{"date-parts":[[2020,7,8]]},
     "DOI":"10.1145/3373718.3394769","publisher":"ACM","page":"425-439",
     "URL":"http://dx.doi.org/10.1145/3373718.3394769"}
    """

    /// api.crossref.org/works?query.bibliographic=..., one item (10.3390/app12188972), enveloped
    /// the way a real search response is. Note title/container-title are ARRAYS here, and the
    /// second author carries an ORCID field this app never asked for, to check that an unknown
    /// key is ignored rather than failing the whole decode.
    private let crossrefSearchFixture = """
    {"status":"ok","message-type":"work-list","message-version":"1.0.0",
     "message":{"total-results":1,"items":[
       {"DOI":"10.3390/app12188972","type":"journal-article",
        "title":["Deep Residual Learning for Image Recognition: A Survey"],
        "container-title":["Applied Sciences"],
        "author":[{"given":"Muhammad","family":"Shafiq"},
                  {"ORCID":"https://orcid.org/0000-0001-7546-852X","given":"Zhaoquan","family":"Gu"}],
        "issued":{"date-parts":[[2022,9,7]]},
        "volume":"12","issue":"18","page":"8972","publisher":"MDPI AG","ISSN":["2076-3417"]}
     ]}}
    """

    /// export.arxiv.org/api/query?id_list=hep-th/9711200, old-scheme id, WITH arxiv:doi and
    /// arxiv:journal_ref -- both only appear once a preprint is formally published.
    private let arxivFeedWithExtras = """
    <?xml version='1.0' encoding='UTF-8'?>
    <feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <id>http://arxiv.org/abs/hep-th/9711200v3</id>
        <title>The Large N Limit of Superconformal Field Theories and Supergravity</title>
        <summary>  We show that the large N limit of certain conformal field theories.</summary>
        <category term="hep-th" scheme="http://arxiv.org/schemas/atom"/>
        <published>1997-11-27T23:53:13Z</published>
        <arxiv:comment>20 pages, harvmac, v2: section on AdS_2 corrected</arxiv:comment>
        <arxiv:primary_category term="hep-th"/>
        <arxiv:journal_ref>Adv.Theor.Math.Phys.2:231-252,1998</arxiv:journal_ref>
        <author><name>Juan M. Maldacena</name></author>
        <arxiv:doi>10.1023/A:1026654312961</arxiv:doi>
      </entry>
    </feed>
    """

    /// export.arxiv.org/api/query?id_list=1706.03762, new-scheme id, no doi or journal_ref:
    /// a preprint with no formal venue yet, and two authors with no orcid/affiliation split.
    private let arxivFeedNoExtras = """
    <?xml version='1.0' encoding='UTF-8'?>
    <feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <id>http://arxiv.org/abs/1706.03762v7</id>
        <title>Attention Is All You Need</title>
        <summary>The dominant sequence transduction models are based on complex recurrent networks.</summary>
        <category term="cs.CL" scheme="http://arxiv.org/schemas/atom"/>
        <category term="cs.LG" scheme="http://arxiv.org/schemas/atom"/>
        <published>2017-06-12T17:57:34Z</published>
        <arxiv:comment>15 pages, 5 figures</arxiv:comment>
        <arxiv:primary_category term="cs.CL"/>
        <author><name>Ashish Vaswani</name></author>
        <author><name>Noam Shazeer</name></author>
      </entry>
    </feed>
    """

    /// openlibrary.org/api/books?bibkeys=ISBN:0201558025&jscmd=data: a subtitle, three
    /// authors, isbn_10 only (an older book, predating ISBN-13).
    private let openLibraryFixtureWithSubtitle = """
    {"ISBN:0201558025":{"title":"Concrete mathematics","subtitle":"a foundation for computer science",
      "authors":[{"name":"Ronald L. Graham"},{"name":"Donald Knuth"},{"name":"Oren Patashnik"}],
      "publishers":[{"name":"Addison-Wesley"}],"publish_date":"1994",
      "identifiers":{"isbn_10":["0201558025"],"lccn":["93040325"],"oclc":["29357079"]}}}
    """

    /// The same endpoint for ISBN 9780134685991: no subtitle, both isbn_10 and isbn_13
    /// present, and a publish_date that is a full written-out date rather than a bare year.
    private let openLibraryFixtureISBN13 = """
    {"ISBN:9780134685991":{"title":"Effective Java",
      "authors":[{"name":"Joshua Bloch"}],
      "publishers":[{"name":"Addison-Wesley Professional"}],"publish_date":"December 27, 2017",
      "identifiers":{"isbn_10":["0134685997"],"isbn_13":["9780134685991"]}}}
    """

    // MARK: - Identifier extraction

    func testExtractDOIFindsTheIdentifierWithVariousSurroundings() {
        XCTAssertEqual(extractDOI(from: "doi:10.1145/3373718.3394769"), "10.1145/3373718.3394769")
        XCTAssertEqual(extractDOI(from: "See https://doi.org/10.1145/3373718.3394769 for details"),
                      "10.1145/3373718.3394769")
        XCTAssertEqual(extractDOI(from: "no identifier anywhere in this text"), nil)
    }

    /// Crossref's own blog documents this: a trailing sentence-final period gets swallowed
    /// into the match. Reproduced here as a fact about the pattern, not something this app
    /// tries to fix (there is no known-correct fix, per the design doc's own research).
    func testExtractDOIReproducesTheDocumentedTrailingPunctuationBycatch() {
        XCTAssertEqual(extractDOI(from: "DOI: 10.1007/978-3-031-84300-6_13."),
                      "10.1007/978-3-031-84300-6_13.")
    }

    /// A first page is full of things shaped like a DOI that are not one. This is not a
    /// defect in extractDOI to fix -- the pattern is Crossref's own -- it is what "the
    /// false positives" in the task means: know what the pattern actually catches.
    func testExtractDOIHasKnownFalsePositives() {
        XCTAssertEqual(extractDOI(from: "Retail price $10.1234/share this quarter"), "10.1234/share",
                      "a decimal price followed by a unit is syntactically indistinguishable from a DOI")
        XCTAssertEqual(extractDOI(from: "manual v10.1234/2024-05 revision"), "10.1234/2024-05")
    }

    func testExtractDOIRejectsShapesThatDoNotFitEvenSyntactically() {
        XCTAssertNil(extractDOI(from: "ISBN 978-3-030-12345-6"), "no bare '10.' prefix")
        XCTAssertNil(extractDOI(from: "See section 10.1: Introduction/Overview"),
                    "only one digit after the decimal point, the pattern needs 4-9")
        XCTAssertNil(extractDOI(from: "identifier 10.123456789012/foo"),
                    "12 digits before the slash is too many for the pattern to bridge to it")
    }

    func testExtractArxivIDTriesNewSchemeThenOldScheme() {
        XCTAssertEqual(extractArxivID(from: "arXiv:1706.03762v7 [cs.CL] 2 Aug 2023"), "1706.03762")
        XCTAssertEqual(extractArxivID(from: "arXiv:0706.0001v1 [q-bio.CB] 1 Jun 2007"), "0706.0001")
        XCTAssertEqual(extractArxivID(from: "arXiv:hep-th/9711200v3"), "hep-th/9711200")
        XCTAssertEqual(extractArxivID(from: "arXiv:math.GT/0309136v1"), "math.GT/0309136")
    }

    func testExtractArxivIDRejectsPartialOrAbsentMatches() {
        XCTAssertNil(extractArxivID(from: "arXiv:12345"), "no dot, does not fit either scheme")
        XCTAssertNil(extractArxivID(from: "See issue 1706.03762 in the tracker"), "no 'arXiv:' prefix at all")
        XCTAssertNil(extractArxivID(from: "nothing relevant here"))
    }

    // MARK: - DOI content negotiation

    func testDoiRequestSetsAcceptAndUserAgentAndAppendsMailtoWhenGiven() {
        let plain = doiRequest(doi: "10.1145/3373718.3394769")
        XCTAssertEqual(plain?.url?.absoluteString, "https://doi.org/10.1145/3373718.3394769")
        XCTAssertEqual(plain?.value(forHTTPHeaderField: "Accept"), "application/vnd.citationstyles.csl+json")
        XCTAssertFalse(plain?.value(forHTTPHeaderField: "User-Agent")?.contains("mailto:") ?? true)

        let identified = doiRequest(doi: "10.1145/3373718.3394769", contact: "person@example.com")
        XCTAssertTrue(identified?.value(forHTTPHeaderField: "User-Agent")?.contains("mailto:person@example.com")
                     ?? false)
    }

    func testParseCSLWorkDecodesTheRealShape() {
        let work = parseCSLWork(Data(cslFixture.utf8))
        XCTAssertEqual(work?.doi, "10.1145/3373718.3394769")
        XCTAssertEqual(work?.title, "Coherence and normalisation-by-evaluation for bicategorical cartesian closed structure")
        XCTAssertEqual(work?.containerTitle, "Proceedings of the 35th Annual ACM/IEEE Symposium on Logic in Computer Science")
        XCTAssertEqual(work?.author?.count, 2)
        XCTAssertEqual(work?.author?.first?.family, "Fiore")
        XCTAssertEqual(work?.issued?.dateParts, [[2020, 7, 8]])
        XCTAssertEqual(work?.publisher, "ACM")
        XCTAssertEqual(work?.page, "425-439")
    }

    func testParseCSLWorkOnGarbageReturnsNilRatherThanCrashing() {
        XCTAssertNil(parseCSLWork(Data("not json at all".utf8)))
        XCTAssertNil(parseCSLWork(Data()))
        XCTAssertNil(parseCSLWork(Data("[1, 2, 3]".utf8)), "a JSON array is valid JSON but not this shape")
    }

    func testFetchDOISucceedsOnAStub() async throws {
        let work = try await fetchDOI("10.1145/3373718.3394769", fetch: stubFetch(json: cslFixture))
        XCTAssertEqual(work.doi, "10.1145/3373718.3394769")
    }

    func testFetchDOIThrowsNotFoundOn404() async {
        do {
            _ = try await fetchDOI("10.9999/nonexistent", fetch: stubFetch(status: 404, json: "{}"))
            XCTFail("expected notFound")
        } catch MetadataError.notFound {
            // expected
        } catch {
            XCTFail("expected .notFound, got \(error)")
        }
    }

    func testFetchDOIThrowsHTTPOnOtherFailureStatus() async {
        do {
            _ = try await fetchDOI("10.1145/3373718.3394769", fetch: stubFetch(status: 503, json: "{}"))
            XCTFail("expected http(503)")
        } catch MetadataError.http(let code) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("expected .http(503), got \(error)")
        }
    }

    func testFetchDOIThrowsUnreadableOnA200WithAnUnparsableBody() async {
        do {
            _ = try await fetchDOI("10.1145/3373718.3394769", fetch: stubFetch(json: "not json"))
            XCTFail("expected unreadable")
        } catch MetadataError.unreadable {
            // expected
        } catch {
            XCTFail("expected .unreadable, got \(error)")
        }
    }

    func testFetchDOIPropagatesATransportFailure() async {
        do {
            _ = try await fetchDOI("10.1145/3373718.3394769", fetch: throwingFetch())
            XCTFail("expected the stub's error to propagate")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("expected StubError, got \(error)")
        }
    }

    // MARK: - Crossref bibliographic search

    func testCrossrefSearchURLIncludesRowsAndOptionalMailto() {
        let url = crossrefSearchURL(bibliographic: "attention is all you need", rows: 3)
        XCTAssertTrue(url?.absoluteString.contains("query.bibliographic=attention") ?? false)
        XCTAssertTrue(url?.absoluteString.contains("rows=3") ?? false)
        XCTAssertFalse(url?.absoluteString.contains("mailto") ?? true)

        let withContact = crossrefSearchURL(bibliographic: "attention is all you need", contact: "person@example.com")
        XCTAssertTrue(withContact?.absoluteString.contains("mailto=person@example.com") ?? false,
                     "'@' is a legal, unencoded character in a URL query component")
    }

    func testParseCrossrefSearchDecodesTheRealShapeIncludingAnUnknownAuthorKey() {
        let items = parseCrossrefSearch(Data(crossrefSearchFixture.utf8))
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.doi, "10.3390/app12188972")
        XCTAssertEqual(item.title, ["Deep Residual Learning for Image Recognition: A Survey"])
        XCTAssertEqual(item.containerTitle, ["Applied Sciences"])
        XCTAssertEqual(item.author?.count, 2)
        XCTAssertEqual(item.author?[1].family, "Gu", "the extra ORCID key on this author must not break decoding")
        XCTAssertEqual(item.volume, "12")
        XCTAssertEqual(item.issue, "18")
        XCTAssertEqual(item.issn, ["2076-3417"])
    }

    func testParseCrossrefSearchOnGarbageReturnsAnEmptyArray() {
        XCTAssertEqual(parseCrossrefSearch(Data("{not json".utf8)), [])
        XCTAssertEqual(parseCrossrefSearch(Data("{\"message\":{}}".utf8)), [], "missing 'items' entirely")
        XCTAssertEqual(parseCrossrefSearch(Data()), [])
    }

    func testSearchCrossrefSucceedsOnAStub() async throws {
        let items = try await searchCrossref(bibliographic: "deep residual learning",
                                             fetch: stubFetch(json: crossrefSearchFixture))
        XCTAssertEqual(items.first?.doi, "10.3390/app12188972")
    }

    func testSearchCrossrefThrowsHTTPOnFailureStatus() async {
        do {
            _ = try await searchCrossref(bibliographic: "x", fetch: stubFetch(status: 429, json: "{}"))
            XCTFail("expected http(429)")
        } catch MetadataError.http(let code) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("expected .http(429), got \(error)")
        }
    }

    func testBibTypeForCrossrefTypeMapsTheDocumentedCasesAndFallsBackToMisc() {
        XCTAssertEqual(bibType(forCrossrefType: "journal-article"), .article)
        XCTAssertEqual(bibType(forCrossrefType: "proceedings-article"), .article)
        XCTAssertEqual(bibType(forCrossrefType: "book"), .book)
        XCTAssertEqual(bibType(forCrossrefType: "book-chapter"), .inbook)
        XCTAssertEqual(bibType(forCrossrefType: "report"), .report)
        XCTAssertEqual(bibType(forCrossrefType: "dataset"), .misc, "not in the mapped vocabulary")
        XCTAssertEqual(bibType(forCrossrefType: "some-future-crossref-type-nobody-has-seen-yet"), .misc)
    }

    // MARK: - arXiv

    func testArxivIDLookupURLUsesIDList() {
        XCTAssertEqual(arxivIDLookupURL(id: "1706.03762")?.absoluteString,
                      "https://export.arxiv.org/api/query?id_list=1706.03762")
    }

    func testArxivTitleSearchURLQuotesTheTitleAsAPhrase() {
        let url = arxivTitleSearchURL(title: "Attention Is All You Need")
        XCTAssertTrue(url?.absoluteString.contains("search_query=ti") ?? false)
        // URLComponents percent-encodes the quotes and spaces; decode back to check the phrase survived whole.
        XCTAssertTrue(url?.query?.removingPercentEncoding?.contains(#"ti:"Attention Is All You Need""#) ?? false)
    }

    func testParseArxivFeedDecodesAnEntryWithDOIAndJournalRef() {
        let entries = parseArxivFeed(Data(arxivFeedWithExtras.utf8))
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.id, "hep-th/9711200")
        XCTAssertEqual(entry.version, 3)
        XCTAssertEqual(entry.title, "The Large N Limit of Superconformal Field Theories and Supergravity")
        XCTAssertEqual(entry.authors, ["Juan M. Maldacena"])
        XCTAssertEqual(entry.primaryCategory, "hep-th")
        XCTAssertEqual(entry.categories, ["hep-th"])
        XCTAssertEqual(entry.doi, "10.1023/A:1026654312961")
        XCTAssertEqual(entry.journalRef, "Adv.Theor.Math.Phys.2:231-252,1998")
        XCTAssertNotNil(entry.published)
    }

    func testParseArxivFeedDecodesAnEntryWithNoDOIOrJournalRefYet() {
        let entries = parseArxivFeed(Data(arxivFeedNoExtras.utf8))
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.id, "1706.03762")
        XCTAssertEqual(entry.version, 7)
        XCTAssertEqual(entry.authors, ["Ashish Vaswani", "Noam Shazeer"])
        XCTAssertEqual(entry.categories, ["cs.CL", "cs.LG"])
        XCTAssertNil(entry.doi, "an eprint with no formal venue yet has none")
        XCTAssertNil(entry.journalRef)
    }

    func testParseArxivFeedOnGarbageOrEmptyFeedReturnsAnEmptyArray() {
        XCTAssertEqual(parseArxivFeed(Data("not xml at all".utf8)), [])
        XCTAssertEqual(parseArxivFeed(Data()), [])
        let emptyFeed = "<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"
        XCTAssertEqual(parseArxivFeed(Data(emptyFeed.utf8)), [], "zero results is a valid, well-formed feed")
    }

    /// A hostile or truncated feed can carry an <entry> with no usable id or title. Rather
    /// than crash or fabricate a value, that entry is dropped and its well-formed siblings
    /// still come through.
    func testParseArxivFeedSkipsEntriesMissingIDOrTitle() {
        let feed = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>No id element at all</title>
          </entry>
          <entry>
            <id>http://arxiv.org/abs/1234.5678v1</id>
          </entry>
          <entry>
            <id>http://arxiv.org/abs/9999.0001v1</id>
            <title>The Only Well-Formed Entry</title>
          </entry>
        </feed>
        """
        let entries = parseArxivFeed(Data(feed.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "9999.0001")
    }

    func testFetchArxivEntryReturnsTheFirstEntryOrNilWhenTheFeedIsEmpty() async throws {
        let entry = try await fetchArxivEntry(id: "hep-th/9711200", fetch: stubFetch(body: Data(arxivFeedWithExtras.utf8)))
        XCTAssertEqual(entry?.id, "hep-th/9711200")

        let emptyFeed = "<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"
        let none = try await fetchArxivEntry(id: "0000.00000", fetch: stubFetch(body: Data(emptyFeed.utf8)))
        XCTAssertNil(none)
    }

    func testSearchArxivSucceedsOnAStub() async throws {
        let entries = try await searchArxiv(title: "Attention Is All You Need",
                                            fetch: stubFetch(body: Data(arxivFeedNoExtras.utf8)))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "1706.03762")
    }

    func testSearchArxivThrowsHTTPOnFailureStatus() async {
        do {
            _ = try await searchArxiv(title: "x", fetch: stubFetch(status: 429, body: Data()))
            XCTFail("expected http(429)")
        } catch MetadataError.http(let code) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("expected .http(429), got \(error)")
        }
    }

    // MARK: - Open Library

    func testOpenLibraryISBNURLShape() {
        let url = openLibraryISBNURL(isbn: "0201558025")
        XCTAssertTrue(url?.absoluteString.hasPrefix("https://openlibrary.org/api/books?") ?? false)
        XCTAssertTrue(url?.absoluteString.contains("bibkeys=ISBN:0201558025") ?? false,
                     "':' is a legal, unencoded character in a URL query component")
        XCTAssertTrue(url?.absoluteString.contains("jscmd=data") ?? false)
    }

    func testParseOpenLibraryBookWithSubtitleAndISBN10Only() {
        let book = parseOpenLibraryBook(Data(openLibraryFixtureWithSubtitle.utf8), isbn: "0201558025")
        XCTAssertEqual(book?.title, "Concrete mathematics")
        XCTAssertEqual(book?.subtitle, "a foundation for computer science")
        XCTAssertEqual(book?.authors, ["Ronald L. Graham", "Donald Knuth", "Oren Patashnik"])
        XCTAssertEqual(book?.publisher, "Addison-Wesley")
        XCTAssertEqual(book?.publishDate, "1994")
        XCTAssertEqual(book?.isbn10, "0201558025")
        XCTAssertNil(book?.isbn13, "this edition predates ISBN-13")
    }

    func testParseOpenLibraryBookWithBothISBNsAndNoSubtitle() {
        let book = parseOpenLibraryBook(Data(openLibraryFixtureISBN13.utf8), isbn: "9780134685991")
        XCTAssertEqual(book?.title, "Effective Java")
        XCTAssertNil(book?.subtitle)
        XCTAssertEqual(book?.isbn10, "0134685997")
        XCTAssertEqual(book?.isbn13, "9780134685991")
        XCTAssertEqual(book?.publishDate, "December 27, 2017")
    }

    /// Open Library omits a bibkey from the response entirely rather than returning a null
    /// or an error object for it, so a plain `{}` is the documented "not found" shape.
    func testParseOpenLibraryBookReturnsNilWhenTheKeyIsAbsent() {
        XCTAssertNil(parseOpenLibraryBook(Data("{}".utf8), isbn: "0000000000000"))
    }

    func testParseOpenLibraryBookOnGarbageReturnsNilRatherThanCrashing() {
        XCTAssertNil(parseOpenLibraryBook(Data("not json".utf8), isbn: "0201558025"))
        XCTAssertNil(parseOpenLibraryBook(Data("[1,2,3]".utf8), isbn: "0201558025"))
        XCTAssertNil(parseOpenLibraryBook(Data(#"{"ISBN:0201558025": "not an object"}"#.utf8), isbn: "0201558025"))
        XCTAssertNil(parseOpenLibraryBook(Data(#"{"ISBN:0201558025": {"authors": []}}"#.utf8), isbn: "0201558025"),
                    "no title at all")
    }

    func testFetchOpenLibraryBookSucceedsOnAStub() async throws {
        let book = try await fetchOpenLibraryBook(isbn: "0201558025",
                                                   fetch: stubFetch(json: openLibraryFixtureWithSubtitle))
        XCTAssertEqual(book?.title, "Concrete mathematics")
    }

    // MARK: - Normalization

    func testCSLWorkNormalizes() {
        let work = parseCSLWork(Data(cslFixture.utf8))!
        let normalized = work.normalized()
        XCTAssertEqual(normalized.source, .doi)
        XCTAssertEqual(normalized.doi, "10.1145/3373718.3394769")
        XCTAssertEqual(normalized.authors, ["Marcelo Fiore", "Philip Saville"])
        XCTAssertEqual(normalized.year, "2020")
        XCTAssertEqual(normalized.pages, "425-439")
        XCTAssertEqual(normalized.type, .article, "proceedings-article maps to .article")
    }

    func testCrossrefWorkNormalizes() {
        let work = parseCrossrefSearch(Data(crossrefSearchFixture.utf8))[0]
        let normalized = work.normalized()
        XCTAssertEqual(normalized.source, .crossref)
        XCTAssertEqual(normalized.title, "Deep Residual Learning for Image Recognition: A Survey")
        XCTAssertEqual(normalized.authors, ["Muhammad Shafiq", "Zhaoquan Gu"])
        XCTAssertEqual(normalized.year, "2022")
        XCTAssertEqual(normalized.volume, "12")
        XCTAssertEqual(normalized.number, "18")
        XCTAssertEqual(normalized.type, .article)
    }

    func testArxivEntryNormalizes() {
        let entry = parseArxivFeed(Data(arxivFeedWithExtras.utf8))[0]
        let normalized = entry.normalized()
        XCTAssertEqual(normalized.source, .arxiv)
        XCTAssertEqual(normalized.arxivID, "hep-th/9711200")
        XCTAssertEqual(normalized.primaryClass, "hep-th")
        XCTAssertEqual(normalized.doi, "10.1023/A:1026654312961")
        XCTAssertEqual(normalized.container, "Adv.Theor.Math.Phys.2:231-252,1998")
        XCTAssertEqual(normalized.year, "1997")
        XCTAssertEqual(normalized.type, .article)
    }

    func testOpenLibraryBookNormalizesTitleAndSubtitleTogether() {
        let book = parseOpenLibraryBook(Data(openLibraryFixtureWithSubtitle.utf8), isbn: "0201558025")!
        let normalized = book.normalized()
        XCTAssertEqual(normalized.source, .openLibrary)
        XCTAssertEqual(normalized.title, "Concrete mathematics: a foundation for computer science")
        XCTAssertEqual(normalized.year, "1994")
        XCTAssertEqual(normalized.isbn, "0201558025", "no isbn13 on this edition, falls back to isbn10")
        XCTAssertEqual(normalized.type, .book)
    }

    func testOpenLibraryBookNormalizesAFreeTextPublishDate() {
        let book = parseOpenLibraryBook(Data(openLibraryFixtureISBN13.utf8), isbn: "9780134685991")!
        let normalized = book.normalized()
        XCTAssertEqual(normalized.title, "Effective Java", "no subtitle, nothing to join")
        XCTAssertEqual(normalized.year, "2017", "pulled out of 'December 27, 2017'")
        XCTAssertEqual(normalized.isbn, "9780134685991", "isbn13 preferred when both are present")
    }

    // MARK: - Merge

    func testMergePrefersDoiOverArxivForFormalFields() {
        let doi = NormalizedMetadata(source: .doi, title: "Coherence and NBE", authors: ["Marcelo Fiore"],
                                     year: "2020", doi: "10.1145/3373718.3394769", container: "LICS 2020",
                                     pages: "425-439", publisher: "ACM", type: .article)
        let arxiv = NormalizedMetadata(source: .arxiv, title: "Coherence and NbE (preprint)",
                                       authors: ["Marcelo Fiore"], year: "2019", arxivID: "1912.00000",
                                       primaryClass: "cs.LO", container: nil, type: .article)
        let merged = mergeMetadata([arxiv, doi])
        XCTAssertEqual(merged.source, .doi)
        XCTAssertEqual(merged.doi, "10.1145/3373718.3394769", "only doi/crossref/arxiv, and doi outranks arxiv")
        XCTAssertEqual(merged.publisher, "ACM", "arxiv never has a publisher to disagree with")
        XCTAssertEqual(merged.pages, "425-439")
        XCTAssertEqual(merged.container, "LICS 2020")
        XCTAssertEqual(merged.arxivID, "1912.00000", "arxivID always comes from the arxiv record specifically")
        XCTAssertEqual(merged.primaryClass, "cs.LO")
    }

    /// doi and arxiv were both reached by an identifier pulled out of the document; a
    /// crossref hit was only ever a guess at which search result was right, so it loses the
    /// title tie-break even though it is listed first in this input array.
    func testMergeTitlePrefersIdentifierAnchoredRecordsOverFuzzyCrossrefSearch() {
        let crossref = NormalizedMetadata(source: .crossref, title: "A Similarly Titled But Wrong Paper",
                                          type: .article)
        let arxiv = NormalizedMetadata(source: .arxiv, title: "Attention Is All You Need", arxivID: "1706.03762",
                                       type: .article)
        let merged = mergeMetadata([crossref, arxiv])
        XCTAssertEqual(merged.title, "Attention Is All You Need")
    }

    /// The design's own documented judgment call: once a work has both a formal venue and
    /// an earlier arXiv posting, the venue year is treated as "the" citation year, not the
    /// year the preprint first appeared.
    func testMergeYearPrefersFormalVenueYearOverArxivPostingYear() {
        let doi = NormalizedMetadata(source: .doi, year: "2020", doi: "10.1145/3373718.3394769", type: .article)
        let arxiv = NormalizedMetadata(source: .arxiv, year: "2019", arxivID: "1912.00000", type: .article)
        XCTAssertEqual(mergeMetadata([doi, arxiv]).year, "2020")
        XCTAssertEqual(mergeMetadata([arxiv]).year, "2019", "with no formal venue at all, the preprint year stands")
    }

    func testMergeAuthorsFallsThroughDoiCrossrefArxivOpenLibraryInOrder() {
        let arxivOnly = NormalizedMetadata(source: .arxiv, authors: ["Ashish Vaswani"], type: .article)
        let crossrefOnly = NormalizedMetadata(source: .crossref, authors: ["A. Vaswani", "N. Shazeer"],
                                              type: .article)
        // crossref's real given/family split outranks arxiv's unsplit name, even though
        // arxiv appears first in this array.
        XCTAssertEqual(mergeMetadata([arxivOnly, crossrefOnly]).authors, ["A. Vaswani", "N. Shazeer"])

        let bookOnly = NormalizedMetadata(source: .openLibrary, authors: ["Donald Knuth"], isbn: "0201558025",
                                          type: .book)
        let noAuthorsElsewhere = NormalizedMetadata(source: .doi, doi: "10.0/x", type: .article)
        XCTAssertEqual(mergeMetadata([noAuthorsElsewhere, bookOnly]).authors, ["Donald Knuth"],
                      "falls all the way back to Open Library when nothing else supplied a name")
    }

    /// An ISBN means an actual book: Open Library becomes the sole source of isbn, title and
    /// the preferred source of publisher, the merged type is forced to .book outright, and
    /// paper-only fields (container/volume/number/pages) are dropped even if some other
    /// source happened to carry a value for them.
    func testMergeWithAnISBNProducesABookRecordThatWinsOverPaperFields() {
        let openLibrary = NormalizedMetadata(source: .openLibrary, title: "Concrete Mathematics",
                                             authors: ["Donald Knuth"], year: "1994", publisher: "Addison-Wesley",
                                             isbn: "0201558025", type: .book)
        let crossref = NormalizedMetadata(source: .crossref, title: "Concrete Mathematics (conference version)",
                                          container: "Proceedings of Something", volume: "3", pages: "1-10",
                                          publisher: "Wrong Publisher Inc.", type: .inbook)
        let merged = mergeMetadata([crossref, openLibrary])
        XCTAssertEqual(merged.source, .openLibrary)
        XCTAssertEqual(merged.title, "Concrete Mathematics",
                      "Open Library's own title wins, not a fuzzy Crossref search hit for some other edition")
        XCTAssertEqual(merged.type, .book)
        XCTAssertEqual(merged.isbn, "0201558025")
        XCTAssertEqual(merged.publisher, "Addison-Wesley", "Open Library's publisher wins for a book")
        XCTAssertNil(merged.container, "a book has no proceedings container")
        XCTAssertNil(merged.volume)
        XCTAssertNil(merged.pages)
    }

    func testMergeWithNoRecordsAtAllStaysTotalAndProducesAnEmptyDefault() {
        let merged = mergeMetadata([])
        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.authors, [])
        XCTAssertNil(merged.doi)
        XCTAssertEqual(merged.type, .misc)
    }

    // MARK: - Live network (opt-in only)

    /// Hits the real doi.org, api.crossref.org, export.arxiv.org and openlibrary.org, to
    /// notice if any of these shapes has drifted since the design doc verified them. Skipped
    /// unless PDFHAMMER_LIVE_METADATA_TESTS is set, so the rest of the suite never depends on
    /// being online -- a test suite that fails on a train is a broken test suite.
    func testLiveShapesHaveNotDrifted() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PDFHAMMER_LIVE_METADATA_TESTS"] != nil,
                          "set PDFHAMMER_LIVE_METADATA_TESTS=1 to run this against the real network")

        let live: HTTPFetch = { request in try await URLSession.shared.data(for: request) }

        let doiWork = try await fetchDOI("10.1145/3373718.3394769", fetch: live)
        XCTAssertEqual(doiWork.doi, "10.1145/3373718.3394769")
        XCTAssertNotNil(doiWork.title)

        let crossrefHits = try await searchCrossref(bibliographic: "attention is all you need", fetch: live)
        XCTAssertFalse(crossrefHits.isEmpty)

        let arxivEntry = try await fetchArxivEntry(id: "1706.03762", fetch: live)
        XCTAssertEqual(arxivEntry?.id, "1706.03762")
        XCTAssertEqual(arxivEntry?.title, "Attention Is All You Need")

        let book = try await fetchOpenLibraryBook(isbn: "0201558025", fetch: live)
        XCTAssertEqual(book?.title, "Concrete mathematics")
    }
}

/// The opening shown under a file's details. It used to be produced by squeezing the whole
/// of whatever text had been extracted, which for a book took about eighty milliseconds,
/// on every pass of the view body that showed three lines of it.
final class SqueezedOpeningTests: XCTestCase {

    func testRunsOfWhitespaceBecomeSingleSpaces() {
        XCTAssertEqual(squeezedOpening(of: "one   two\n\nthree\t four"), "one two three four")
    }

    func testLeadingAndTrailingWhitespaceGoes() {
        XCTAssertEqual(squeezedOpening(of: "\n  hello  \n"), "hello")
    }

    func testNothingInNothingOut() {
        XCTAssertEqual(squeezedOpening(of: "   \n\t "), "")
    }

    /// The bound is what keeps this cheap. A book's worth of text must not be walked to
    /// fill three lines.
    func testOnlyTheOpeningIsRead() {
        let text = String(repeating: "word ", count: 100_000)
        let opening = squeezedOpening(of: text, limit: 100)
        XCTAssertLessThanOrEqual(opening.count, 100)
        XCTAssertTrue(opening.hasPrefix("word word"))
    }

    /// The bound counts characters of the source, so a partial word at the end is kept
    /// rather than dropped: three lines of text should not end mid-word for the sake of
    /// tidiness nobody asked for.
    func testTheCutIsNotPaddedOrTrimmedBeyondWhitespace() {
        XCTAssertEqual(squeezedOpening(of: "abcdefgh", limit: 5), "abcde")
    }
}
