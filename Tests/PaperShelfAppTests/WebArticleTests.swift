import XCTest
import WebKit
import PDFKit
import PaperShelfCore
@testable import PaperShelf

@MainActor
final class WebArticleTests: XCTestCase {
    func testCitationAndSourceSurviveSavingAndAnnotatingPDF() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(scratchName("web-citation"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("article.pdf")
        try makeTextPDF(at: file, text: "A statement from a saved website.")
        let document = try XCTUnwrap(PDFDocument(url: file))
        let article = WebArticle(url: URL(string: "https://example.org/a?x=1&y=2")!,
                                 title: "Truth & {proof}", authors: ["Jane Doe"], published: "2025-04-02")
        try article.embed(in: document)
        let selection = try XCTUnwrap(document.findString("saved website", withOptions: []).first)
        XCTAssertEqual(addPDFHighlights(for: selection, colour: .systemYellow, note: "Check this").count, 1)
        XCTAssertTrue(document.write(to: file))
        let reopened = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertEqual(WebArticle.read(from: reopened), article)
        XCTAssertTrue(article.bibtex.contains("title = {Truth \\& \\{proof\\}}"))
        XCTAssertTrue(article.bibtex.contains("year = {2025}"))
        XCTAssertFalse(WebArticle(url: article.url, title: "Unknown author").bibtex.contains("author ="))
        XCTAssertFalse(WebArticle(url: article.url, title: "Unknown date").bibtex.contains("year ="))
        let legacy = try JSONEncoder().encode(article)
        XCTAssertEqual(try JSONDecoder().decode(WebArticle.self, from: legacy), article)
    }

    func testNavigationAcceptsWebURLsOnly() {
        XCTAssertEqual(WebArticle.navigationURL("plato.stanford.edu/entries/logic/ ")?.scheme, "https")
        for value in ["", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,test",
                      "https://user:password@example.org", "a search query"] {
            XCTAssertNil(WebArticle.navigationURL(value), value)
        }
    }

    func testWebKitMetadataAndFullPageCapture() async throws {
        _ = NSApplication.shared
        let model = WebReaderModel()
        let web = model.webView
        web.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let navigation = FinishedNavigation()
        web.navigationDelegate = navigation
        let finished = expectation(description: "Fixture loaded")
        navigation.finished = { finished.fulfill() }
        web.loadHTMLString("""
            <html><head><meta name="citation_title" content="Evidence & reasoning">
            <meta name="citation_author" content="Jane Doe"><meta name="citation_author" content="John Smith">
            <meta name="DC.creator" content="Jane Doe"><meta name="DC.creator" content="John Smith">
            <meta name="citation_publication_date" content="2024-03-01"></head>
            <body><nav>Navigation noise.</nav><p>Unique opening passage.</p><div style="height:1800px"></div><p>Last passage below the fold.</p></body></html>
            """, baseURL: URL(string: "https://example.org/article"))
        await fulfillment(of: [finished], timeout: 15)
        let rawFacts = try await web.evaluateJavaScript(WebReaderModel.metadataScript)
        let facts = try XCTUnwrap(rawFacts as? [String: Any])
        XCTAssertEqual(facts["authors"] as? [String], ["Jane Doe", "John Smith"])
        XCTAssertEqual(facts["title"] as? String, "Evidence & reasoning")
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 800, height: (facts["height"] as? Double) ?? 0)
        let data = try await web.pdf(configuration: configuration)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(pdf.string?.contains("Last passage below the fold.") == true)
        XCTAssertEqual(pdf.findString("Unique opening passage.", withOptions: []).count, 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(scratchName("web-freeze"))
        defer { try? FileManager.default.removeItem(at: folder) }
        model.loaded = true
        let first = await model.freeze(destination: folder, library: nil)
        let saved = try XCTUnwrap(first, model.error ?? "Snapshot missing")
        let original = try Data(contentsOf: saved)
        let paginated = try XCTUnwrap(PDFDocument(data: original))
        XCTAssertGreaterThan(paginated.pageCount, 1, "Long articles need readable pages, not a single strip")
        XCTAssertTrue(paginated.string?.contains("Last passage below the fold.") == true)
        XCTAssertFalse(paginated.string?.contains("Navigation noise.") == true)
        for pageIndex in 0..<paginated.pageCount {
            let bounds = try XCTUnwrap(paginated.page(at: pageIndex)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, 595.28, accuracy: 1)
            XCTAssertEqual(bounds.height, 841.89, accuracy: 1)
        }
        let citationFile = saved.deletingPathExtension().appendingPathExtension("bib")
        let originalCitation = try String(contentsOf: citationFile, encoding: .utf8)
        _ = try await web.evaluateJavaScript("""
            document.querySelector('meta[name="citation_title"]').content = 'Revised evidence';
            document.querySelector('meta[name="citation_author"]').content = 'Revised Author';
            const modified = document.createElement('meta');
            modified.name = 'dcterms.modified'; modified.content = '2026-09-08';
            document.head.appendChild(modified);
            true;
            """)
        let second = await model.freeze(destination: folder, library: nil)
        let revised = try XCTUnwrap(second, model.error ?? "Revised snapshot missing")
        let revisedPDF = try XCTUnwrap(PDFDocument(url: revised))
        let revisedArticle = try XCTUnwrap(WebArticle.read(from: revisedPDF))
        XCTAssertEqual(revisedArticle.title, "Revised evidence")
        XCTAssertEqual(revisedArticle.authors.first, "Revised Author")
        XCTAssertEqual(revisedArticle.modified, "2026-09-08")
        XCTAssertTrue(revisedArticle.bibtex.contains("year = {2024}"), "Revision must not replace publication year")
        XCTAssertTrue(revisedArticle.bibtex.contains("page last updated 2026-09-08"))
        XCTAssertEqual(try String(contentsOf: revised.deletingPathExtension().appendingPathExtension("bib"), encoding: .utf8), revisedArticle.bibtex)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: saved), original, "Resync must preserve the old version")
        XCTAssertEqual(try String(contentsOf: citationFile, encoding: .utf8), originalCitation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.deletingPathExtension().appendingPathExtension("webarchive").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.deletingPathExtension().appendingPathExtension("bib").path))

        // An equation renderer finishing after the HTML load must land in the reading copy.
        _ = try await web.evaluateJavaScript("""
            window.MathJax = {startup: {promise: new Promise(resolve => {
              setTimeout(() => {
                document.body.insertAdjacentHTML('beforeend', '<p>Typeset equation ready</p><math><mfrac><mn>1</mn><mn>2</mn></mfrac><mo>+</mo><mi>x</mi><mo>=</mo><mn>3</mn></math>');
                resolve();
              }, 1000);
            })}};
            true;
            """)
        let mathFile = await model.freeze(destination: folder, library: nil)
        let mathPDF = try XCTUnwrap(PDFDocument(url: XCTUnwrap(mathFile, model.error ?? "Math snapshot missing")))
        XCTAssertTrue(mathPDF.string?.contains("Typeset equation ready") == true, mathPDF.string ?? "No PDF text")
        XCTAssertTrue(mathPDF.string?.contains("𝑥") == true || mathPDF.string?.contains("x") == true,
                      mathPDF.string ?? "No PDF text")

        _ = try await web.evaluateJavaScript("window.MathJax.startup.promise = new Promise(() => {}); true;")
        do {
            try await model.prepareCapture(timeoutMilliseconds: 25)
            XCTFail("An unfinished math renderer must not be saved silently")
        } catch { XCTAssertTrue(error.localizedDescription.contains("still loading"), error.localizedDescription) }
    }
}

@MainActor
private final class FinishedNavigation: NSObject, WKNavigationDelegate {
    var finished: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
}
