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
    }

    func testNavigationAcceptsWebURLsOnly() {
        XCTAssertEqual(WebArticle.navigationURL("plato.stanford.edu/entries/logic/ ")?.scheme, "https")
        for value in ["", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,test",
                      "https://user:password@example.org", "a search query"] {
            XCTAssertNil(WebArticle.navigationURL(value), value)
        }
    }

    func testWebKitMetadataAndFullPageCapture() async throws {
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
            <body><p>Unique opening passage.</p><div style="height:1800px"></div><p>Last passage below the fold.</p></body></html>
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
        let second = await model.freeze(destination: folder, library: nil)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: saved), original, "Resync must preserve the old version")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.deletingPathExtension().appendingPathExtension("webarchive").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.deletingPathExtension().appendingPathExtension("bib").path))
    }
}

@MainActor
private final class FinishedNavigation: NSObject, WKNavigationDelegate {
    var finished: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
}
