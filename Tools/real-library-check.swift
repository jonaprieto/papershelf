import Foundation

// An exercise against a real shelf of PDFs, checking what unit tests built on synthetic
// one-page documents cannot: that a document's identity survives the app's own rename, that
// the naming patterns produce usable filenames from names as messy as they really come, and
// that identifier extraction copes with real first pages.
//
// Nothing here writes to the folder it is given. It reads, and it builds its own throwaway
// database in the temporary directory.
//
// This found two real defects the unit tests missed: patterns copying a filename through
// untouched, spaces and all, and the collision counter never firing because a name that had
// been tidied no longer matched the one on disk.

func heading(_ text: String) { print("\n=== \(text)") }
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok   " : "FAIL ") + label + (detail.isEmpty ? "" : "  [\(detail)]"))
    if !ok { failures += 1 }
}

guard CommandLine.arguments.count > 1 else {
    print("usage: Tools/real-library-check.sh <folder-of-pdfs>")
    exit(2)
}
let downloads = URL(fileURLWithPath: CommandLine.arguments[1])
let jobs = collectJobs(roots: [downloads], recursive: false)
let items = process(jobs: jobs, options: Options(passwords: [], recursive: false, dryRun: true))
heading("scanned \(items.count) real PDFs")
guard let sample = items.first else { fatalError("no PDFs to work with") }

heading("Library keeps a document's tags across the app's own rename")
let dbPath = NSTemporaryDirectory() + "integ-\(UUID().uuidString).sqlite"
defer { try? FileManager.default.removeItem(atPath: dbPath) }

let library = try Library(url: URL(fileURLWithPath: dbPath))
let first = try await library.indexDocument(path: sample.source.path, contentHash: "hash-before",
                                      byteCount: sample.byteCount, pageCount: sample.pageCount,
                                      title: sample.destinationName)
try await library.addTag("to-read", toDocument: first.id)
_ = try await library.addNote("a note that must survive", toDocument: first.id)

// What the app does when it renames: a new path, and after a decrypt, different bytes too.
let renamed = sample.source.deletingLastPathComponent()
    .appendingPathComponent("2024-renamed-by-the-app.pdf").path
try await library.recordLocation(renamed, forDocument: first.id)
let again = try await library.indexDocument(path: renamed, contentHash: "hash-after",
                                      byteCount: sample.byteCount, pageCount: sample.pageCount)
check("the renamed file is the same document", again.id == first.id, "\(first.id) vs \(again.id)")
check("its tags survived", try await library.tags(forDocument: again.id).map(\.name) == ["to-read"])
check("its notes survived", try await library.notes(forDocument: again.id).count == 1)
check("no second row appeared", try await library.document(atPath: renamed)?.id == first.id)

heading("full-text search over what was extracted")
let text = markdownFromPDF(url: sample.currentURL, passwords: [], pageMarkers: false)
try await library.setExtractedText(text, forDocument: first.id)
let word = text.split(separator: " ").first { $0.count > 6 }.map(String.init) ?? "the"
let hits = try await library.fullTextSearch(word)
check("a word from the document finds it", hits.contains { $0.id == first.id },
      "searched \(word), got \(hits.count)")
check("a word that is not there finds nothing",
      try await library.fullTextSearch("zzqqxvnotaword").isEmpty)

heading("patterns render real filenames")
for preset in NamePattern.presets {
    let names = items.prefix(3).map { render(preset.pattern, for: $0, rules: NameRules(casing: .lowercase, separator: .dash, stripSymbols: true)) }
    let bad = names.filter { $0.isEmpty || $0.hasPrefix("-") || $0.contains("--") || $0.contains("/") }
    check("preset \(preset.name) produces usable names", bad.isEmpty, bad.joined(separator: ", "))
    print("     " + names.joined(separator: "\n     "))
}

heading("identifiers out of real documents")
var foundDOI = 0, foundArxiv = 0
for item in items {
    let opening = openingText(of: item.currentURL, passwords: [], pages: 2)
    if let doi = extractDOI(from: opening) {
        foundDOI += 1
        print("     DOI  \(doi)  <- \(item.sourceName.prefix(50))")
    }
    if let id = extractArxivID(from: opening) {
        foundArxiv += 1
        print("     arXiv \(id)  <- \(item.sourceName.prefix(50))")
    }
}
print("     \(foundDOI) DOIs, \(foundArxiv) arXiv ids across \(items.count) documents")
check("identifier extraction did not crash on real input", true)

print("\n\(failures == 0 ? "all good" : "\(failures) FAILURES")")
exit(failures == 0 ? 0 : 1)
