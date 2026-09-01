import XCTest
@testable import PaperShelf

final class WebsiteTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func values(of attribute: String, in html: String) -> [String] {
        let pattern = "\\b\(attribute)=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[valueRange])
        }
    }

    private func toolNames(in source: String) -> Set<String> {
        let pattern = "\\bname:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[valueRange])
        })
    }

    func testLandingPageListsTheCurrentHighlighterMeanings() throws {
        let html = try String(contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"), encoding: .utf8)
        XCTAssertEqual(values(of: "data-highlight-meaning", in: html), Palette.defaults.map(\.meaning))
    }

    func testLandingPageListsEveryRegisteredMCPTool() throws {
        let html = try String(contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"), encoding: .utf8)
        let pageTools = Set(values(of: "data-mcp-tool", in: html))
        let files = ["Tools.swift", "LibraryTools.swift", "HighlightTools.swift", "WriteTools.swift"]
        let source = try files.map {
            try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/PaperShelfMCP/\($0)"), encoding: .utf8)
        }.joined(separator: "\n")
        let expected = toolNames(in: source)
        XCTAssertEqual(pageTools, expected)
        XCTAssertEqual(pageTools.count, 18)
    }
}
