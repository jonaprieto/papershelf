import Foundation
import PDFKit
import CryptoKit

// MARK: - Filename normalization

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern)
}

private enum DateShape {
    case yearMonthDay
    case dayMonthYear
    case yearMonth
    case year
}

/// Date shapes recognised in a filename, most specific first. Separators are required,
/// which is what keeps a long digit run such as `20240612` from being carved up, and the
/// digit lookarounds stop a match starting mid-number.
///
/// `DD-MM-YYYY` is read day-first, the convention in bank statements in much of Latin America and Europe.
/// An ambiguous `05-08-2026` is therefore August, not May.
private let datePatterns: [(NSRegularExpression, DateShape)] = [
    (regex("(?<![0-9])((?:19|20)[0-9]{2})[-_./ ](0[1-9]|1[0-2])[-_./ ](0[1-9]|[12][0-9]|3[01])(?![0-9])"),
     .yearMonthDay),
    (regex("(?<![0-9])(0[1-9]|[12][0-9]|3[01])[-_./ ](0[1-9]|1[0-2])[-_./ ]((?:19|20)[0-9]{2})(?![0-9])"),
     .dayMonthYear),
    (regex("(?<![0-9])((?:19|20)[0-9]{2})[-_.](0[1-9]|1[0-2])(?![0-9])"),
     .yearMonth),
    (regex("(?<![0-9])((?:19|20)[0-9]{2})(?![0-9])"),
     .year),
]

private struct FoundDate {
    let prefix: String
    let range: NSRange
}

/// First match of the most specific shape present.
private func findDate(in stem: String) -> FoundDate? {
    let full = NSRange(location: 0, length: (stem as NSString).length)
    for (pattern, shape) in datePatterns {
        guard let m = pattern.firstMatch(in: stem, range: full) else { continue }
        let ns = stem as NSString
        func group(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        switch shape {
        case .yearMonthDay, .yearMonth:
            return FoundDate(prefix: "\(group(1))-\(group(2))", range: m.range)
        case .dayMonthYear:
            return FoundDate(prefix: "\(group(3))-\(group(2))", range: m.range)
        case .year:
            return FoundDate(prefix: group(1), range: m.range)
        }
    }
    return nil
}

/// How a stem is cleaned up once the date has been lifted out of it. The defaults are a
/// no-op beyond lowercasing, so a name only changes shape when a rule is switched on.
public struct NameRules: Sendable, Equatable {
    public enum Casing: String, Sendable, CaseIterable, Identifiable {
        case lowercase, uppercase, unchanged
        public var id: String { rawValue }
    }

    /// What to write where the original had runs of spaces, dashes or underscores.
    public enum Separator: String, Sendable, CaseIterable, Identifiable {
        case keep, dash, underscore
        public var id: String { rawValue }
    }

    public var casing: Casing
    public var separator: Separator
    /// Treat anything that is not a letter or digit as a separator, so `report (1)!`
    /// becomes `report-1` rather than keeping the punctuation.
    public var stripSymbols: Bool
    /// Fold accents: `señor` becomes `senor`.
    public var stripDiacritics: Bool

    public init(
        casing: Casing = .lowercase,
        separator: Separator = .keep,
        stripSymbols: Bool = false,
        stripDiacritics: Bool = false
    ) {
        self.casing = casing
        self.separator = separator
        self.stripSymbols = stripSymbols
        self.stripDiacritics = stripDiacritics
    }

    public static let standard = NameRules()

    /// Character written between the date prefix and the slug. The prefix itself always
    /// stays `YYYY-MM`, since a date is not a word separator.
    var joiner: Character { separator == .underscore ? "_" : "-" }
}

private let plainSeparators: Set<Character> = ["-", "_", " "]

/// Collapses runs of separators to a single character, trims them from both ends, and
/// applies the casing, symbol and accent rules. Whitespace of every kind, including
/// non-breaking spaces, is always a separator and never survives.
private func tidy(_ input: String, _ rules: NameRules) -> String {
    var text = input
    if rules.stripDiacritics {
        text = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    switch rules.casing {
    case .lowercase: text = text.lowercased()
    case .uppercase: text = text.uppercased()
    case .unchanged: break
    }

    func isSeparator(_ ch: Character) -> Bool {
        if plainSeparators.contains(ch) || ch.isWhitespace { return true }
        return rules.stripSymbols && !ch.isLetter && !ch.isNumber
    }

    var out = ""
    var runStart: Character?
    for ch in text {
        guard isSeparator(ch) else {
            if let start = runStart {
                if !out.isEmpty { out.append(separatorCharacter(for: start, rules)) }
                runStart = nil
            }
            out.append(ch)
            continue
        }
        if runStart == nil { runStart = ch }
    }
    return out
}

/// With `keep`, a run keeps the character it started with, so `abc123_-` stays an
/// underscore. A run that began on stripped punctuation has no character worth keeping,
/// so it falls back to a dash.
private func separatorCharacter(for runStart: Character, _ rules: NameRules) -> Character {
    switch rules.separator {
    case .dash: return "-"
    case .underscore: return "_"
    case .keep: return runStart == "_" ? "_" : "-"
    }
}

/// Filename stems that carry no information, so the enclosing folder is worth borrowing.
private let genericStems: Set<String> = [
    "document", "documento", "doc", "docs", "file", "archivo", "scan", "scanned",
    "escaneo", "escaneado", "untitled", "sintitulo", "pdf", "download", "downloaded",
    "descarga", "descargado", "image", "img", "new", "nuevo", "copy", "copia",
]

/// True when the stem says nothing: empty, digits only (`001`), or a generic word
/// possibly followed by digits (`scan001`, `documento-2`).
private func isUninformative(_ slug: String) -> Bool {
    if slug.isEmpty { return true }
    let letters = slug.filter { $0.isLetter }
    if letters.isEmpty { return true }
    return genericStems.contains(String(letters).lowercased())
}

/// A date and a name lifted from the folders a file sits in.
public struct FolderContext: Sendable, Equatable {
    public let prefix: String?
    public let slug: String?
    public static let none = FolderContext(prefix: nil, slug: nil)
}

/// Walks from the file's own folder up to the selected root, nearest first, taking the
/// first date it finds and the first folder name that leaves something once its date is
/// removed. `bank/2024/Extracto Marzo.pdf` yields the date `2024` and the name `bank`.
public func folderContext(for file: URL, under root: URL, rules: NameRules = .standard) -> FolderContext {
    var prefix: String?
    var slug: String?
    var directory = file.deletingLastPathComponent()
    let rootPath = root.standardizedFileURL.path

    while true {
        let name = directory.lastPathComponent
        let found = findDate(in: name)
        if prefix == nil { prefix = found?.prefix }
        if slug == nil {
            let cleaned = found
                .map { tidy((name as NSString).replacingCharacters(in: $0.range, with: "-"), rules) }
                ?? tidy(name, rules)
            if !cleaned.isEmpty { slug = cleaned }
        }
        if prefix != nil && slug != nil { break }
        if directory.standardizedFileURL.path == rootPath { break }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    return FolderContext(prefix: prefix, slug: slug)
}

private let monthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM"
    return f
}()

/// Normalizes `filename` to `<date>-<slug>.pdf`, lowercased.
///
/// The date token is lifted out of the stem wherever it sits and re-attached at the
/// front, so a name that already starts with its date comes back unchanged rather than
/// gaining a second prefix.
///
/// - Parameters:
///   - preferredDate: overrides the date found in the filename. The filename's own date
///     token is still stripped out of the slug, so the name does not end up carrying two.
///   - fallbackDate: used only when the filename holds no date at all.
/// Formats a date the way a prefix is written.
public func monthPrefix(_ date: Date) -> String {
    monthFormatter.string(from: date)
}

/// Normalizes `filename` to `<date>-<slug>.pdf`.
///
/// A date already present in the filename always wins. That is the only date the
/// document itself asserts, and replacing it with a timestamp taken from the file loses
/// information that cannot be recovered: an annual statement for 2024 may well have been
/// generated in 2025, and its filename is right where its metadata is not.
///
/// - Parameters:
///   - fallbackPrefixes: consulted in order, and only when the filename holds no date.
///   - folderSlug: used in place of a stem that says nothing (`scan001`, `document`).
public func normalizedName(
    for filename: String,
    fallbackPrefixes: [String] = [],
    folderSlug: String? = nil,
    rules: NameRules = .standard
) -> String {
    let stem = (filename as NSString).deletingPathExtension
    let found = findDate(in: stem)   // digits only, so case cannot matter

    // Replace rather than delete so `foo2024bar` does not become `foobar`.
    var slug = found.map { tidy((stem as NSString).replacingCharacters(in: $0.range, with: "-"), rules) }
        ?? tidy(stem, rules)

    // `scan001.pdf` in a folder called `acme66` is worth more as `acme66-scan001`.
    if let folderSlug, isUninformative(slug) {
        slug = slug.isEmpty ? folderSlug : "\(folderSlug)\(rules.joiner)\(slug)"
    }

    let prefix = found?.prefix ?? fallbackPrefixes.first { !$0.isEmpty }

    // A stem made entirely of stripped punctuation would otherwise leave just ".pdf".
    guard let prefix else { return slug.isEmpty ? filename : slug + ".pdf" }
    return slug.isEmpty ? "\(prefix).pdf" : "\(prefix)\(rules.joiner)\(slug).pdf"
}

/// Recomputes what a file would be called under different naming rules, using only the
/// dates already captured when it was first read. No PDF is opened, so the whole list
/// can be restyled as fast as a switch can be flipped.
public func restyled(_ item: Item, options: Options) -> Item {
    var fallbacks: [String] = []
    if options.useFolderNames,
       let folderPrefix = folderContext(for: item.source, under: item.root, rules: options.rules).prefix {
        fallbacks.append(folderPrefix)
    }
    if options.useMetadataDate, let date = item.metadataDate { fallbacks.append(monthPrefix(date)) }
    if options.useFileDate, let date = item.modifiedDate { fallbacks.append(monthPrefix(date)) }

    let context = options.useFolderNames
        ? folderContext(for: item.source, under: item.root, rules: options.rules)
        : .none
    let name = normalizedName(
        for: item.sourceName,
        fallbackPrefixes: fallbacks,
        folderSlug: context.slug,
        rules: options.rules
    )

    var restyled = item
    restyled.destination = availableURL(
        item.source.deletingLastPathComponent().appendingPathComponent(name),
        ignoring: item.source
    )
    return restyled
}

/// Restyles a whole list. Independent per item, so it runs across cores.
public func restyled(_ list: [Item], options: Options) -> [Item] {
    guard list.count > 1 else { return list.map { restyled($0, options: options) } }
    var slots = [Item?](repeating: nil, count: list.count)
    slots.withUnsafeMutableBufferPointer { buffer in
        DispatchQueue.concurrentPerform(iterations: list.count) { index in
            buffer[index] = restyled(list[index], options: options)
        }
    }
    return slots.compactMap { $0 }
}

// MARK: - Folder scope

/// The folder a file sits in, resolved so it lines up with `Item.key`.
public func folderPath(of item: Item) -> String {
    item.source.deletingLastPathComponent().resolvingSymlinksInPath().path
}

/// Every item in `folder` or anywhere beneath it. The trailing slash is what keeps
/// `bank` from also matching a sibling called `bank-old`.
public func items(under folder: String, in list: [Item]) -> [Item] {
    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
    return list.filter { $0.key.hasPrefix(prefix) }
}

// MARK: - Password list

/// The password list is stored as one newline-separated string so it fits in a single
/// preference. Blank rows are kept, so a freshly added one does not vanish while it is
/// being typed into.
///
/// The awkward case: `"".components(separatedBy: "\n")` is `[""]`, one blank row rather
/// than none, so an empty list and a list holding one empty row are the same string.
/// Adding therefore always appends a newline, including to an empty string.
public enum PasswordList {
    public static func rows(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    public static func adding(to text: String) -> String {
        text + "\n"
    }

    /// Adding a row when the last one is still blank would just pile up empty fields, so
    /// in that case the existing blank is reused. Returns the text to store and the row
    /// to put the caret in.
    public static func addingRow(to text: String) -> (text: String, focus: Int) {
        let list = rows(text)
        if list.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            return (text, list.count - 1)
        }
        let grown = adding(to: text)
        return (grown, rows(grown).count - 1)
    }

    /// Trying the same password twice is wasted work on every encrypted file.
    public static func active(_ text: String) -> [String] {
        var seen = Set<String>()
        return rows(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func removing(_ index: Int, from text: String) -> String {
        var list = rows(text)
        guard list.indices.contains(index) else { return text }
        list.remove(at: index)
        return list.joined(separator: "\n")
    }

    public static func setting(_ index: Int, to value: String, in text: String) -> String {
        var list = rows(text)
        guard list.indices.contains(index) else { return text }
        list[index] = value.replacingOccurrences(of: "\n", with: "")
        return list.joined(separator: "\n")
    }

}

// MARK: - Processing

public enum Status: String, Sendable, CaseIterable {
    case decrypted   // was encrypted, password found, written out unencrypted
    case renamed     // not encrypted, passed through untouched
    case locked      // encrypted, no password matched, passed through still encrypted
    case trashed     // marked for deletion during review, moved to the Trash
    case failed
}

public struct Item: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let source: URL
    public var destination: URL
    public var status: Status
    public var message: String = ""
    /// Kept from the run that produced this item, so changing a naming rule can be
    /// answered from memory instead of opening every PDF again.
    public var metadataDate: Date?
    public var modifiedDate: Date?
    public var byteCount: Int?

    /// Stable identity for the file on disk. Symlinks are resolved because a URL built
    /// by the caller (`/var/...`) and one handed back by the filesystem
    /// (`/private/var/...`) name the same file with different strings.
    public var key: String { source.resolvingSymlinksInPath().path }

    public var sourceName: String { source.lastPathComponent }
    public var destinationName: String { destination.lastPathComponent }
    public var isRenamed: Bool { sourceName != destinationName }

    /// Path of the source relative to the selected root, used to build the results tree.
    public var relativePath: String { relative(source, under: root) }
}

public struct Options: Sendable {
    public var passwords: [String]
    public var recursive: Bool
    public var dryRun: Bool
    /// Move each original into `original_pdfs/`. Off means the file is replaced in place.
    public var moveOriginals: Bool
    /// All three only apply when the filename itself carries no date, and are consulted
    /// in this order. None of them can displace a date the filename already states.
    public var useFolderNames: Bool
    public var useMetadataDate: Bool
    public var useFileDate: Bool
    public var rules: NameRules

    public init(
        passwords: [String],
        recursive: Bool,
        dryRun: Bool,
        moveOriginals: Bool = true,
        useFolderNames: Bool = true,
        useMetadataDate: Bool = false,
        useFileDate: Bool = false,
        rules: NameRules = .standard
    ) {
        self.passwords = passwords
        self.recursive = recursive
        self.dryRun = dryRun
        self.moveOriginals = moveOriginals
        self.useFolderNames = useFolderNames
        self.useMetadataDate = useMetadataDate
        self.useFileDate = useFileDate
        self.rules = rules
    }
}

public let backupDirectoryName = "original_pdfs"

/// A PDF paired with the root the user selected, which is where its backup goes.
public struct Job: Identifiable, Sendable {
    public let root: URL
    public let file: URL
    /// Matches `Item.key`, so an override survives the round trip through a preview.
    public var key: String { file.resolvingSymlinksInPath().path }
    public var id: String { key }
}

private let fm = FileManager.default

private func isDirectory(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
}

private func relative(_ url: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1))
        : url.lastPathComponent
}

/// A directory still to be visited, carried with the root the user picked.
private struct PendingDirectory {
    let root: URL
    let url: URL
}

/// Expands the selection into concrete PDFs. Anything already inside a backup
/// directory is left alone so re-running never reprocesses its own output.
///
/// The walk is breadth-first with each level read in parallel, which matters on network
/// and cloud-sync volumes where a directory read is latency-bound rather than CPU-bound.
/// `contentsOfDirectory` prefetches `isDirectory`, so classifying an entry costs no extra
/// stat call.
///
/// `progress` is called from arbitrary threads with the directory just read and the
/// running total of PDFs found.
public func collectJobs(
    roots: [URL],
    recursive: Bool,
    progress: (@Sendable (String, Int) -> Void)? = nil
) -> [Job] {
    let lock = NSLock()
    var jobs: [Job] = []
    var seen = Set<String>()

    // Caller holds `lock`. `pathComponents` and `standardizedFileURL` both allocate, so
    // neither belongs on the per-file path: the walk already skips backup directories,
    // and entries come straight from `contentsOfDirectory` already standardized.
    func record(root: URL, file: URL) {
        guard file.pathExtension.lowercased() == "pdf" else { return }
        guard seen.insert(file.path).inserted else { return }
        jobs.append(Job(root: root, file: file))
    }

    var frontier: [PendingDirectory] = []
    for selection in roots {
        if isDirectory(selection) {
            frontier.append(PendingDirectory(root: selection, url: selection))
        } else {
            // A file named directly still has to be checked, since no walk filtered it.
            guard !selection.pathComponents.contains(backupDirectoryName) else { continue }
            lock.lock()
            record(root: selection.deletingLastPathComponent(), file: selection.standardizedFileURL)
            lock.unlock()
        }
    }

    let keys: [URLResourceKey] = [.isDirectoryKey]
    while !frontier.isEmpty {
        let level = frontier
        var next: [PendingDirectory] = []

        DispatchQueue.concurrentPerform(iterations: level.count) { index in
            let pending = level[index]
            let entries = (try? fm.contentsOfDirectory(
                at: pending.url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []

            var files: [URL] = []
            var directories: [PendingDirectory] = []
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    guard recursive, url.lastPathComponent != backupDirectoryName else { continue }
                    directories.append(PendingDirectory(root: pending.root, url: url))
                } else {
                    files.append(url)
                }
            }

            lock.lock()
            for file in files { record(root: pending.root, file: file) }
            next.append(contentsOf: directories)
            let total = jobs.count
            lock.unlock()

            progress?(pending.url.path, total)
        }

        frontier = next
    }

    return jobs.sorted { $0.file.path < $1.file.path }
}

private func modificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

private func byteCount(_ url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
}

// MARK: - Duplicates

/// Copy markers a downloader or a file manager appends: `(1)`, `-2`, `copy`, `copia`.
///
/// A bare trailing number is only treated as a marker when it follows a dash or
/// underscore with no space. `Catch 22` is a title; `book-2` is a second copy.
private let copyMarkers = regex("(?:[ _-]*\\((?:copy|copia|[0-9]{1,3})\\)|[ _-]+(?:copy|copia)|[_-][0-9]{1,2})$")

/// A key that ignores everything a second download changes: the date, any copy marker,
/// and every separator. `Book (1).pdf`, `book-2.pdf` and `Book 2024.pdf` all land on
/// `book`.
public func duplicateKey(for filename: String) -> String {
    var stem = (filename as NSString).deletingPathExtension.lowercased()
    if let found = findDate(in: stem) {
        stem = (stem as NSString).replacingCharacters(in: found.range, with: " ")
    }
    // Exactly one marker is stripped. Stripping repeatedly would eat `catch-22-2` down
    // to `catch`, merging Catch-22 with any book called Catch.
    var trimmed = stem
    if let match = copyMarkers.firstMatch(in: stem, range: NSRange(location: 0, length: (stem as NSString).length)) {
        trimmed = (stem as NSString).replacingCharacters(in: match.range, with: "")
    }
    return trimmed.filter { $0.isLetter || $0.isNumber }
}

/// SHA-256 of the file, read in chunks so a large book is never held whole in memory.
public func fileDigest(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

public struct DuplicateGroup: Identifiable, Sendable {
    public enum Kind: String, Sendable { case identical, likely }

    public let id: String
    public let kind: Kind
    /// Best copy first: the one worth keeping.
    public let items: [Item]

    public var keeper: Item { items[0] }
    public var extras: [Item] { Array(items.dropFirst()) }
}

/// The copy worth keeping: biggest file first, since a truncated download is smaller,
/// then the shortest name, which is the one without `(1)` bolted on.
private func rank(_ a: Item, _ b: Item) -> Bool {
    let sizeA = a.byteCount ?? 0, sizeB = b.byteCount ?? 0
    if sizeA != sizeB { return sizeA > sizeB }
    if a.sourceName.count != b.sourceName.count { return a.sourceName.count < b.sourceName.count }
    return a.key < b.key
}

/// Finds files that are the same book twice.
///
/// Byte-identical copies are found by hashing, but only within groups that already share
/// a size, so a collection of thousands is not read from end to end to answer a question
/// most files settle by size alone. What is left is grouped by `duplicateKey`, which
/// catches the same book downloaded twice under slightly different names.
public func duplicateGroups(in items: [Item]) -> [DuplicateGroup] {
    var bySize: [Int: [Item]] = [:]
    for item in items where item.byteCount != nil {
        bySize[item.byteCount!, default: []].append(item)
    }

    let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
    var digests: [String: String] = [:]
    if !candidates.isEmpty {
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            guard let digest = fileDigest(candidates[index].source) else { return }
            lock.lock()
            digests[candidates[index].key] = digest
            lock.unlock()
        }
    }

    var identical: [String: [Item]] = [:]
    for item in candidates {
        guard let digest = digests[item.key] else { continue }
        identical[digest, default: []].append(item)
    }

    var groups: [DuplicateGroup] = []
    var claimed = Set<String>()
    for (digest, group) in identical where group.count > 1 {
        let sorted = group.sorted(by: rank)
        groups.append(DuplicateGroup(id: digest, kind: .identical, items: sorted))
        claimed.formUnion(sorted.map(\.key))
    }

    var byName: [String: [Item]] = [:]
    for item in items where !claimed.contains(item.key) {
        let key = duplicateKey(for: item.sourceName)
        guard !key.isEmpty else { continue }
        byName[key, default: []].append(item)
    }
    for (key, group) in byName where group.count > 1 {
        groups.append(DuplicateGroup(id: "name:" + key, kind: .likely, items: group.sorted(by: rank)))
    }

    return groups.sorted { $0.keeper.sourceName < $1.keeper.sourceName }
}

/// Returns `url` if free, otherwise `name-2.pdf`, `name-3.pdf`, ...
private func availableURL(_ url: URL, ignoring: URL? = nil) -> URL {
    if !fm.fileExists(atPath: url.path) { return url }
    if let ignoring, url.standardizedFileURL == ignoring.standardizedFileURL { return url }
    let base = url.deletingPathExtension().path
    let ext = url.pathExtension
    var n = 2
    while true {
        let candidate = URL(fileURLWithPath: "\(base)-\(n).\(ext)")
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}

/// Path under `<root>/original_pdfs/` mirroring the file's position beneath `root`.
private func backupURL(for job: Job) -> URL {
    job.root
        .appendingPathComponent(backupDirectoryName)
        .appendingPathComponent(relative(job.file, under: job.root))
}

/// PDFKit's `write(to:)` carries the source document's encryption dictionary over even
/// after a successful unlock, so a genuinely decrypted file has to be rebuilt page by
/// page into a fresh document. Verified against PDFKit on macOS 26.
private func decryptedCopy(of doc: PDFDocument) -> PDFDocument? {
    guard doc.pageCount > 0 else { return nil }
    let clean = PDFDocument()
    for index in 0..<doc.pageCount {
        guard let page = doc.page(at: index)?.copy() as? PDFPage else { return nil }
        clean.insert(page, at: clean.pageCount)
    }
    clean.documentAttributes = doc.documentAttributes
    return clean
}

/// Makes a user-typed name safe to use as a filename: no path separators, no colons,
/// never empty, always a `.pdf`.
public func sanitizedFilename(_ name: String) -> String {
    // Separators become dashes rather than being dropped, then leading dots and dashes
    // go, so `../../etc/passwd` reads `etc-passwd` and never a hidden file.
    var cleaned = name
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: " ./-_\t\n"))
    if cleaned.isEmpty { cleaned = "untitled" }
    if !cleaned.lowercased().hasSuffix(".pdf") { cleaned += ".pdf" }
    return cleaned
}

/// Runs the whole selection. `progress` is called after each file with (done, total, name).
///
/// A real run stays serial on purpose: collision suffixes (`-2`, `-3`) are decided by
/// probing the filesystem, so running files concurrently would let two of them claim the
/// same name, and the suffix a file ends up with would change run to run.
///
/// A dry run changes nothing on disk, so nothing it does can race. Opening every PDF is
/// what a preview spends its time on, and over a large folder that is worth spreading
/// across cores.
/// `overrides` maps `Job.key` (equivalently `Item.key`) to a name the user typed,
/// replacing the one the rules would have produced.
/// `trashed` holds `Job.key`s to move to the Trash instead of renaming.
public func process(
    jobs: [Job],
    options: Options,
    overrides: [String: String] = [:],
    trashed: Set<String> = [],
    progress: ((Int, Int, String) -> Void)? = nil
) -> [Item] {
    func run(_ job: Job) -> Item {
        trashed.contains(job.key)
            ? moveToTrash(job, dryRun: options.dryRun)
            : process(job: job, options: options, overrideName: overrides[job.key])
    }

    guard options.dryRun, jobs.count > 1 else {
        var items: [Item] = []
        items.reserveCapacity(jobs.count)
        for (index, job) in jobs.enumerated() {
            items.append(run(job))
            progress?(index + 1, jobs.count, job.file.lastPathComponent)
        }
        return items
    }

    var slots = [Item?](repeating: nil, count: jobs.count)
    let lock = NSLock()
    var completed = 0
    slots.withUnsafeMutableBufferPointer { buffer in
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let item = run(jobs[index])
            buffer[index] = item
            lock.lock()
            completed += 1
            let done = completed
            lock.unlock()
            progress?(done, jobs.count, jobs[index].file.lastPathComponent)
        }
    }
    return slots.compactMap { $0 }
}

/// Deletion always means the Trash. Nothing here removes a file outright, so a mistake
/// made during review is still recoverable from Finder afterwards.
public func moveToTrash(_ job: Job, dryRun: Bool) -> Item {
    let source = job.file
    func item(_ destination: URL, _ status: Status, _ message: String = "") -> Item {
        Item(root: job.root, source: source, destination: destination,
             status: status, message: message)
    }
    guard !dryRun else { return item(source, .trashed, "will be moved to the Trash") }
    do {
        var moved: NSURL?
        try fm.trashItem(at: source, resultingItemURL: &moved)
        return item((moved as URL?) ?? source, .trashed, "moved to the Trash")
    } catch {
        return item(source, .failed, "could not move to the Trash: \(error.localizedDescription)")
    }
}

public func process(job: Job, options: Options, overrideName: String? = nil) -> Item {
    let source = job.file
    let directory = source.deletingLastPathComponent()

    var facts: (metadata: Date?, modified: Date?) = (nil, nil)
    var size: Int?
    func item(_ destination: URL, _ status: Status, _ message: String = "") -> Item {
        Item(root: job.root, source: source, destination: destination,
             status: status, message: message,
             metadataDate: facts.metadata, modifiedDate: facts.modified, byteCount: size)
    }

    // Read into memory: a real run moves the original out from under us part-way.
    // Measured against `PDFDocument(url:)`, which pages the file in lazily: reading the
    // bytes is the faster of the two even at 37KB, and only one file is held at a time.
    guard let data = try? Data(contentsOf: source), let doc = PDFDocument(data: data) else {
        return item(source, .failed, "cannot read PDF")
    }

    let wasEncrypted = doc.isEncrypted
    var unlocked = !doc.isLocked
    if doc.isLocked {
        for password in options.passwords where doc.unlock(withPassword: password) {
            unlocked = true
            break
        }
    }
    let status: Status = !wasEncrypted ? .renamed : (unlocked ? .decrypted : .locked)

    // Document attributes are unreadable while the PDF is still locked.
    let metadataDate = unlocked
        ? doc.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
        : nil
    let context = options.useFolderNames
        ? folderContext(for: source, under: job.root, rules: options.rules)
        : .none

    facts = (metadataDate, modificationDate(source))
    size = byteCount(source)

    var fallbacks: [String] = []
    if options.useFolderNames, let folderPrefix = context.prefix { fallbacks.append(folderPrefix) }
    if options.useMetadataDate, let metadataDate { fallbacks.append(monthPrefix(metadataDate)) }
    if options.useFileDate, let modified = facts.modified { fallbacks.append(monthPrefix(modified)) }

    let newName = overrideName.map(sanitizedFilename) ?? normalizedName(
        for: source.lastPathComponent,
        fallbackPrefixes: fallbacks,
        folderSlug: context.slug,
        rules: options.rules
    )

    if options.dryRun {
        let planned = availableURL(directory.appendingPathComponent(newName), ignoring: source)
        return item(planned, status)
    }

    if options.moveOriginals {
        let backup = availableURL(backupURL(for: job))
        do {
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: backup)
        } catch {
            return item(source, .failed, "backup failed: \(error.localizedDescription)")
        }

        // The source name is free now that the original has moved to the backup tree.
        let destination = availableURL(directory.appendingPathComponent(newName))
        do {
            if status == .decrypted {
                guard let clean = decryptedCopy(of: doc), clean.write(to: destination) else {
                    try fm.copyItem(at: backup, to: destination)
                    return item(destination, .failed,
                                "could not write decrypted copy; original restored under new name")
                }
            } else {
                // Byte-for-byte copy: nothing to decrypt, so do not re-serialize through PDFKit.
                try fm.copyItem(at: backup, to: destination)
            }
        } catch {
            return item(destination, .failed, error.localizedDescription)
        }
        return item(destination, status)
    }

    // No backup: the original is consumed. Write the replacement to a temporary file
    // first so a failure part-way through never leaves the folder without the document.
    let destination = availableURL(directory.appendingPathComponent(newName), ignoring: source)
    do {
        if status == .decrypted {
            let temp = directory.appendingPathComponent(".pdfhammer-\(UUID().uuidString).pdf")
            guard let clean = decryptedCopy(of: doc), clean.write(to: temp) else {
                try? fm.removeItem(at: temp)
                return item(source, .failed, "could not write decrypted copy; original left untouched")
            }
            try fm.removeItem(at: source)
            try fm.moveItem(at: temp, to: destination)
        } else if destination.standardizedFileURL != source.standardizedFileURL {
            try fm.moveItem(at: source, to: destination)
        }
    } catch {
        return item(destination, .failed, error.localizedDescription)
    }
    return item(destination, status)
}

// MARK: - Results tree

public struct Node: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// `Item.key`, or nil for a folder. A key rather than the item itself, so applying a
    /// single file does not invalidate the tree it sits in.
    public let itemKey: String?
    public var children: [Node]?
}

/// Groups results back into the folder hierarchy they came from. A single selected
/// folder with no subfolders is flattened, since one root disclosure adds nothing.
public func buildTree(_ items: [Item]) -> [Node] {
    final class Builder {
        let name: String
        var order: [String] = []
        var children: [String: Builder] = [:]
        var itemKey: String?
        init(_ name: String) { self.name = name }

        func child(_ key: String, named name: String) -> Builder {
            if let existing = children[key] { return existing }
            let made = Builder(name)
            children[key] = made
            order.append(key)
            return made
        }

        func node(prefix: String) -> Node {
            let id = prefix + "/" + name
            guard itemKey == nil else {
                return Node(id: id, name: name, itemKey: itemKey, children: nil)
            }
            return Node(id: id, name: name, itemKey: nil,
                        children: order.map { children[$0]!.node(prefix: id) })
        }
    }

    let top = Builder("")
    for item in items {
        var cursor = top.child(item.root.path, named: item.root.lastPathComponent)
        let components = item.relativePath.split(separator: "/").map(String.init)
        for component in components {
            cursor = cursor.child(component, named: component)
        }
        cursor.itemKey = item.key
    }

    let roots = top.order.map { top.children[$0]!.node(prefix: "") }
    if roots.count == 1, let only = roots.first, let children = only.children,
       children.allSatisfy({ $0.itemKey != nil }) {
        return children
    }
    return roots
}
