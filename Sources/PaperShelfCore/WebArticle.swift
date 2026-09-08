import Foundation
import PDFKit

/// Citation facts supplied by the page, retained with the exact reading copy they describe.
public struct WebArticle: Codable, Equatable, Sendable {
    public var url: URL
    public var title: String
    public var authors: [String]
    public var published: String?
    public var modified: String?
    public var site: String?
    public var doi: String?
    public var capturedAt: Date
    public var version: UUID
    public var previousVersion: UUID?

    public init(url: URL, title: String, authors: [String] = [], published: String? = nil,
                site: String? = nil, doi: String? = nil, modified: String? = nil, capturedAt: Date = Date(),
                version: UUID = UUID(), previousVersion: UUID? = nil) {
        self.url = url
        self.title = title
        self.authors = authors
        self.published = published
        self.modified = modified
        self.site = site
        self.doi = doi
        self.capturedAt = capturedAt
        self.version = version
        self.previousVersion = previousVersion
    }

    public static func navigationURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let url = URL(string: text.contains(":") ? text : "https://" + text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public var bibtex: String {
        var fields = [("title", title), ("url", url.absoluteString),
                      ("urldate", String(ISO8601DateFormatter().string(from: capturedAt).prefix(10)))]
        if !authors.isEmpty { fields.append(("author", authors.joined(separator: " and "))) }
        if let published, published.count >= 4,
           published.prefix(4).allSatisfy(\.isNumber) {
            fields.append(("year", String(published.prefix(4))))
            fields.append(("date", published.replacingOccurrences(of: "/", with: "-")))
        }
        if let site, !site.isEmpty { fields.append(("howpublished", site)) }
        if let doi, !doi.isEmpty { fields.append(("doi", doi)) }
        var note = "Local snapshot captured " + ISO8601DateFormatter().string(from: capturedAt)
        if let modified, !modified.isEmpty { note += "; page last updated " + modified }
        fields.append(("note", note))
        return "@misc{web\(version.uuidString.replacingOccurrences(of: "-", with: "").lowercased()),\n"
            + fields.map { "  \($0.0) = {\(Self.escape($0.1))}" }.joined(separator: ",\n") + "\n}"
    }

    private static func escape(_ value: String) -> String {
        value.map { character -> String in
            switch character {
            case "\\": return "\\textbackslash{}"
            case "{", "}", "%", "&", "#", "_", "$": return "\\" + String(character)
            case "~": return "\\textasciitilde{}"
            case "^": return "\\textasciicircum{}"
            case "\n", "\r": return " "
            default: return String(character)
            }
        }.joined()
    }

    /// A standard PDF metadata field survives moves, renames and annotation saves.
    public func embed(in document: PDFDocument) throws {
        let encoded = try JSONEncoder().encode(self).base64EncodedString()
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.authorAttribute] = authors.joined(separator: "; ")
        attributes[PDFDocumentAttribute.subjectAttribute] = "PaperShelfWebArticle:" + encoded
        document.documentAttributes = attributes
    }

    public static func read(from document: PDFDocument) -> WebArticle? {
        guard let subject = document.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
              subject.hasPrefix("PaperShelfWebArticle:"),
              let data = Data(base64Encoded: String(subject.dropFirst("PaperShelfWebArticle:".count))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
