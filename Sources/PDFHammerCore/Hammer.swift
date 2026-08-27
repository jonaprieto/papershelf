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

struct FoundDate {
    let prefix: String
    let range: NSRange
}

/// First match of the most specific shape present.
func findDate(in stem: String) -> FoundDate? {
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

    /// Where the date goes once it has been lifted out of the name.
    public enum DatePosition: String, Sendable, CaseIterable, Identifiable {
        case prefix, suffix
        public var id: String { rawValue }
        public var label: String { self == .prefix ? "Front" : "End" }
    }

    /// How the date itself is written.
    public enum DateFormat: String, Sendable, CaseIterable, Identifiable {
        case dashed, compact
        public var id: String { rawValue }
        public var label: String { self == .dashed ? "2024-06" : "202406" }
    }

    public var casing: Casing
    public var separator: Separator
    /// Treat anything that is not a letter or digit as a separator, so `report (1)!`
    /// becomes `report-1` rather than keeping the punctuation.
    public var stripSymbols: Bool
    /// Fold accents: `señor` becomes `senor`.
    public var stripDiacritics: Bool
    /// Treat anything outside ASCII as a separator, for filesystems and tools that are
    /// unhappy with anything else.
    public var asciiOnly: Bool
    /// Drop a leading `the`, `a`, `el`, `los`, and their friends, so a shelf sorts by
    /// what the book is called rather than by its article.
    public var dropLeadingArticles: Bool
    /// Cut the name back to this many characters, on a word boundary. Zero leaves it.
    public var maxLength: Int
    public var datePosition: DatePosition
    public var dateFormat: DateFormat

    public init(
        casing: Casing = .lowercase,
        separator: Separator = .keep,
        stripSymbols: Bool = false,
        stripDiacritics: Bool = false,
        asciiOnly: Bool = false,
        dropLeadingArticles: Bool = false,
        maxLength: Int = 0,
        datePosition: DatePosition = .prefix,
        dateFormat: DateFormat = .dashed
    ) {
        self.casing = casing
        self.separator = separator
        self.stripSymbols = stripSymbols
        self.stripDiacritics = stripDiacritics
        self.asciiOnly = asciiOnly
        self.dropLeadingArticles = dropLeadingArticles
        self.maxLength = maxLength
        self.datePosition = datePosition
        self.dateFormat = dateFormat
    }

    public static let standard = NameRules()

    /// Character written between the date prefix and the slug. The prefix itself always
    /// stays `YYYY-MM`, since a date is not a word separator.
    var joiner: Character { separator == .underscore ? "_" : "-" }
}

private let plainSeparators: Set<Character> = ["-", "_", " "]

/// Leading words worth dropping so a shelf sorts by the title rather than the article.
private let leadingArticles: Set<String> = [
    "the", "a", "an", "el", "la", "los", "las", "un", "una", "unos", "unas",
    "le", "les", "der", "die", "das", "il", "lo", "o", "os", "as",
]

/// Removes leading articles, one at a time, from an already-tidied slug.
private func withoutLeadingArticles(_ slug: String) -> String {
    var current = slug
    while let index = current.firstIndex(where: { plainSeparators.contains($0) }) {
        let head = String(current[current.startIndex..<index]).lowercased()
        guard leadingArticles.contains(head) else { break }
        current = String(current[current.index(after: index)...])
    }
    return current
}

/// Cuts a slug back to `limit`, preferring the last word boundary inside the budget so a
/// name ends on a whole word rather than mid-syllable.
private func clipped(_ slug: String, to limit: Int) -> String {
    guard limit > 0, slug.count > limit else { return slug }
    let cut = String(slug.prefix(limit))
    if let boundary = cut.lastIndex(where: { plainSeparators.contains($0) }) {
        let head = String(cut[cut.startIndex..<boundary])
        if !head.isEmpty { return head }
    }
    return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
}

/// Collapses runs of separators to a single character, trims them from both ends, and
/// applies the casing, symbol and accent rules. Whitespace of every kind, including
/// non-breaking spaces, is always a separator and never survives.
func tidy(_ input: String, _ rules: NameRules) -> String {
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
        // Anything unrepresentable becomes a break rather than vanishing, so the words
        // either side do not run together.
        if rules.asciiOnly && !ch.isASCII { return true }
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

    if rules.dropLeadingArticles { slug = withoutLeadingArticles(slug) }
    slug = clipped(slug, to: rules.maxLength)

    let prefix = found?.prefix ?? fallbackPrefixes.first { !$0.isEmpty }

    // A stem made entirely of stripped punctuation would otherwise leave just ".pdf".
    guard let prefix else { return slug.isEmpty ? filename : slug + ".pdf" }
    let date = rules.dateFormat == .compact
        ? prefix.replacingOccurrences(of: "-", with: "")
        : prefix
    guard !slug.isEmpty else { return "\(date).pdf" }
    return rules.datePosition == .prefix
        ? "\(date)\(rules.joiner)\(slug).pdf"
        : "\(slug)\(rules.joiner)\(date).pdf"
}

/// Recomputes what a file would be called under different naming rules, using only the
/// dates already captured when it was first read. No PDF is opened, so the whole list
/// can be restyled as fast as a switch can be flipped.
public func restyled(_ item: Item, options: Options, guess: BookGuess? = nil) -> Item {
    // A name the model produced is still only a suggestion of title, author and year:
    // the rules decide how those are written, so they are reapplied here rather than
    // the AI's spelling being frozen in place.
    if let guess {
        let name = filename(for: guess, rules: options.rules)
        if !name.isEmpty {
            var restyled = item
            restyled.destination = availableURL(
                item.source.deletingLastPathComponent().appendingPathComponent(name),
                ignoring: item.source
            )
            return restyled
        }
    }
    return restyledFromName(item, options: options)
}

private func restyledFromName(_ item: Item, options: Options) -> Item {
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
public func restyled(_ list: [Item], options: Options,
                     known: [String: BookGuess] = [:]) -> [Item] {
    guard list.count > 1 else {
        return list.map { restyled($0, options: options, guess: known[$0.key]) }
    }
    var slots = [Item?](repeating: nil, count: list.count)
    slots.withUnsafeMutableBufferPointer { buffer in
        DispatchQueue.concurrentPerform(iterations: list.count) { index in
            buffer[index] = restyled(list[index], options: options, guess: known[list[index].key])
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

// MARK: - Sources

/// True when `child` is `parent` itself, or sits anywhere beneath it.
private func covers(_ parent: URL, _ child: URL) -> Bool {
    guard isDirectory(parent) else { return false }
    let parentPath = parent.resolvingSymlinksInPath().path
    let childPath = child.resolvingSymlinksInPath().path
    return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
}

/// Folds `adding` into `current` so the selection stays a set of non-overlapping roots.
///
/// Overlap is not harmless: a file reachable from two selected folders would be
/// attributed to whichever was scanned first, and that root decides where its
/// `original_pdfs/` backup lands. Selecting a folder therefore absorbs anything already
/// selected beneath it, and anything already covered is never added.
public func mergedSources(_ current: [URL], adding additions: [URL]) -> [URL] {
    var result = current
    for candidate in additions {
        let resolved = candidate.resolvingSymlinksInPath()
        // Already covered, by itself or by a folder above it.
        if result.contains(where: { covers($0, resolved) || $0.resolvingSymlinksInPath() == resolved }) {
            continue
        }
        // This one supersedes anything already selected inside it.
        result.removeAll { covers(resolved, $0) }
        result.append(candidate)
    }
    return result
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

public enum Status: String, Sendable, CaseIterable, Codable {
    case decrypted   // was encrypted, password found, written out unencrypted
    case renamed     // not encrypted, passed through untouched
    case locked      // encrypted, no password matched, passed through still encrypted
    case trashed     // marked for deletion during review, moved to the Trash
    case moved       // sent to a folder you chose, under its new name
    case failed
}

public struct Item: Identifiable, Sendable, Codable {
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
    public var pageCount: Int?
    /// True once the file has actually been written or moved, which is when `source`
    /// stops describing anywhere that exists.
    public var carriedOut: Bool = false
    /// What the PDF says about itself. Often empty, often wrong, occasionally the one
    /// thing that identifies a file whose name says nothing.
    public var documentInfo: [String: String] = [:]

    /// Stable identity for the file on disk. Symlinks are resolved because a URL built
    /// by the caller (`/var/...`) and one handed back by the filesystem
    /// (`/private/var/...`) name the same file with different strings.
    public var key: String { source.resolvingSymlinksInPath().path }

    public var sourceName: String { source.lastPathComponent }
    public var destinationName: String { destination.lastPathComponent }
    public var isRenamed: Bool { sourceName != destinationName }

    /// Where the file is now.
    ///
    /// `source` is where it started and stays fixed, because `key` is derived from it and
    /// identity has to survive the operation. Anything that reads or shows the file has
    /// to use this instead, or it will be looking at a path that no longer exists.
    ///
    /// `key` and `currentURL` are also the pair the library needs to keep a moved
    /// document's tags, notes and project membership: `key` is the path it already knows
    /// the file under, `currentURL` is where it went. `process()` deliberately does not
    /// call the library itself, even though it is the function that performs the move.
    /// Library is an actor, and `process()` is a pure synchronous function that a real run
    /// calls in a tight serial loop and a preview calls across `concurrentPerform`; making
    /// it async would either serialise every file behind the library's queue or force
    /// every caller to restructure around something that has nothing to do with reading a
    /// PDF. The app layer holds both `key` and `currentURL` once `process()` returns, so it
    /// is the one that records the move (see `Runner.syncLibrary`).
    public var currentURL: URL { carriedOut ? destination : source }

    /// Path of the source relative to the selected root, used to build the results tree.
    public var relativePath: String { relative(source, under: root) }

    /// `id` is deliberately absent: it is fresh per process and means nothing once
    /// written down. `key` is the identity that survives, and it is derived from `source`.
    private enum CodingKeys: String, CodingKey {
        case root, source, destination, status, message
        case metadataDate, modifiedDate, byteCount, pageCount, documentInfo, carriedOut
    }
}

public struct Options: Sendable {
    public var passwords: [String]
    public var recursive: Bool
    public var dryRun: Bool
    public var backup: BackupSettings
    /// Move each original aside. Off means the file is replaced in place.
    public var moveOriginals: Bool { backup.enabled }
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
        backup: BackupSettings = .standard,
        useFolderNames: Bool = true,
        useMetadataDate: Bool = false,
        useFileDate: Bool = false,
        rules: NameRules = .standard
    ) {
        self.passwords = passwords
        self.recursive = recursive
        self.dryRun = dryRun
        self.backup = backup
        self.useFolderNames = useFolderNames
        self.useMetadataDate = useMetadataDate
        self.useFileDate = useFileDate
        self.rules = rules
    }
}

public let defaultBackupFolderName = "original_pdfs"

/// Where originals go once a file has been rewritten.
public struct BackupSettings: Sendable, Equatable {
    public var enabled: Bool
    /// A single path component, created inside each selected root.
    public var folderName: String
    /// One folder for everything, anywhere on disk. Wins over `folderName`.
    public var customLocation: URL?

    public init(enabled: Bool = true,
                folderName: String = defaultBackupFolderName,
                customLocation: URL? = nil) {
        self.enabled = enabled
        self.folderName = folderName
        self.customLocation = customLocation
    }

    /// A usable single path component. Anything that would escape the root, name the
    /// root itself, or hide the folder is refused and the default is used instead.
    public var safeFolderName: String {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.hasPrefix("."),
              trimmed != ".." else { return defaultBackupFolderName }
        return trimmed
    }

    public static let standard = BackupSettings()
}

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
    backup: BackupSettings = .standard,
    progress: (@Sendable (String, Int) -> Void)? = nil
) -> [Job] {
    let skipName = backup.safeFolderName
    let skipPath = backup.customLocation?.resolvingSymlinksInPath().path
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
            guard !selection.pathComponents.contains(skipName) else { continue }
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
                    guard recursive, url.lastPathComponent != skipName else { continue }
                    if let skipPath, url.resolvingSymlinksInPath().path == skipPath { continue }
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

// MARK: - Sorting

/// How the results are ordered. Folder order is the default, since it matches where the
/// files actually live; the rest are for answering a question about the set.
public enum ItemSort: String, Sendable, CaseIterable, Identifiable {
    case folder, newName, originalName, size, pages, modified, status

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .folder: return "Folder"
        case .newName: return "New name"
        case .originalName: return "Original name"
        case .size: return "Size"
        case .pages: return "Pages"
        case .modified: return "Date"
        case .status: return "Status"
        }
    }

    /// True when bigger or newer belongs at the top, which is what you want from a
    /// question like "what is taking up the space".
    public var descendsByDefault: Bool {
        self == .size || self == .pages || self == .modified
    }
}

/// Orders items. The tree keeps insertion order, so sorting the list sorts within each
/// folder as well as across a flat view.
///
/// Positions are sorted rather than the items themselves. An `Item` carries three URLs
/// and a dictionary, so every swap during a sort retains and releases them; comparing is
/// cheap, moving is not. String keys are computed once up front for the same reason,
/// since `localizedStandardCompare` is far too expensive to call O(n log n) times.
public func sorted(_ items: [Item], by order: ItemSort, descending: Bool? = nil) -> [Item] {
    guard items.count > 1 else { return items }
    let down = descending ?? order.descendsByDefault

    var indices = Array(items.indices)
    switch order {
    case .folder, .newName, .originalName, .status:
        let keys: [String] = items.map { item in
            switch order {
            case .folder: return item.source.path
            case .newName: return item.destinationName
            case .originalName: return item.sourceName
            default: return item.status.rawValue + "\u{1}" + item.key
            }
        }
        indices.sort { a, b in
            let result = keys[a].localizedStandardCompare(keys[b])
            if result == .orderedSame { return a < b }
            return down ? result == .orderedDescending : result == .orderedAscending
        }
    case .size, .pages, .modified:
        let keys: [Double] = items.map { item in
            switch order {
            case .size: return Double(item.byteCount ?? 0)
            case .pages: return Double(item.pageCount ?? 0)
            default: return item.modifiedDate?.timeIntervalSince1970 ?? 0
            }
        }
        indices.sort { a, b in
            if keys[a] == keys[b] { return a < b }
            return down ? keys[a] > keys[b] : keys[a] < keys[b]
        }
    }
    return indices.map { items[$0] }
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
    /// How the copies were matched, most trustworthy first.
    public enum Kind: String, Sendable {
        /// The same bytes.
        case identical
        /// Different bytes, but the opening pages read the same.
        case sameText
        /// Only the names agree.
        case likely
    }

    public let id: String
    public let kind: Kind
    /// Best copy first: the one worth keeping.
    public var items: [Item]

    public var keeper: Item { items[0] }
    public var extras: [Item] { Array(items.dropFirst()) }

    /// Moves one copy to the front. Which copy is worth keeping is a judgement the
    /// ranking can only guess at, so it has to be overridable.
    public mutating func keep(_ key: String) {
        guard let index = items.firstIndex(where: { $0.key == key }), index != 0 else { return }
        let chosen = items.remove(at: index)
        items.insert(chosen, at: 0)
    }

    /// Bytes that would come back by keeping only one copy.
    public var reclaimable: Int { extras.reduce(0) { $0 + ($1.byteCount ?? 0) } }
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
/// A fingerprint of what the opening pages say, or nil when there is not enough text to
/// be sure of anything.
///
/// The length floor is the important part: a scan with no text layer yields nothing, and
/// without a floor every such file would fingerprint identically and the whole shelf
/// would be reported as one enormous duplicate. Page count joins the hash so two
/// different works that happen to open with the same boilerplate stay apart.
public func contentKey(for item: Item, passwords: [String], pages: Int = 3,
                       minimumCharacters: Int = 240) -> String? {
    let text = openingText(of: item.currentURL, passwords: passwords, pages: pages)
    let squeezed = text.lowercased().filter { $0.isLetter || $0.isNumber }
    guard squeezed.count >= minimumCharacters else { return nil }
    var hasher = SHA256()
    hasher.update(data: Data(squeezed.utf8))
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return "\(item.pageCount ?? 0):\(digest)"
}

public func duplicateGroups(in items: [Item], passwords: [String] = []) -> [DuplicateGroup] {
    var bySize: [Int: [Item]] = [:]
    for item in items where item.byteCount != nil {
        bySize[item.byteCount!, default: []].append(item)
    }

    let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
    var digests: [String: String] = [:]
    if !candidates.isEmpty {
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            guard let digest = fileDigest(candidates[index].currentURL) else { return }
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

    // Same book, different bytes: re-encoded, re-downloaded, or one copy encrypted.
    let unclaimed = items.filter { !claimed.contains($0.key) }
    if !unclaimed.isEmpty {
        var keys = [String?](repeating: nil, count: unclaimed.count)
        keys.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: unclaimed.count) { index in
                buffer[index] = contentKey(for: unclaimed[index], passwords: passwords)
            }
        }
        var byText: [String: [Item]] = [:]
        for (index, item) in unclaimed.enumerated() {
            guard let key = keys[index] else { continue }
            byText[key, default: []].append(item)
        }
        for (key, group) in byText where group.count > 1 {
            let sorted = group.sorted(by: rank)
            groups.append(DuplicateGroup(id: "text:" + key, kind: .sameText, items: sorted))
            claimed.formUnion(sorted.map(\.key))
        }
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

/// True when both URLs name the same file on disk, whatever they spell it like.
///
/// APFS is case-insensitive by default, so `Bus-Oslo.pdf` and `bus-oslo.pdf` are one
/// file. Comparing the paths as strings says otherwise, which made every rename that
/// only changed case look like a collision and collect a needless `-2`.
private func sameFile(_ a: URL, _ b: URL) -> Bool {
    if a.standardizedFileURL == b.standardizedFileURL { return true }
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    guard let one = (try? a.resourceValues(forKeys: keys))?.fileResourceIdentifier,
          let two = (try? b.resourceValues(forKeys: keys))?.fileResourceIdentifier
    else { return false }
    return one.isEqual(two)
}

/// Returns `url` if free, otherwise `name-2.pdf`, `name-3.pdf`, ...
private func availableURL(_ url: URL, ignoring: URL? = nil) -> URL {
    if !fm.fileExists(atPath: url.path) { return url }
    if let ignoring, sameFile(url, ignoring) { return url }
    let base = url.deletingPathExtension().path
    let ext = url.pathExtension
    var n = 2
    while true {
        let candidate = URL(fileURLWithPath: "\(base)-\(n).\(ext)")
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}

/// Where this file's original belongs, mirroring its position beneath the selected root.
///
/// A custom location holds every root, so the root's own name is kept as the first
/// component: without it, two roots each holding `2024/statement.pdf` would collide.
private func backupURL(for job: Job, _ backup: BackupSettings) -> URL {
    let tail = relative(job.file, under: job.root)
    if let custom = backup.customLocation {
        return custom
            .appendingPathComponent(job.root.lastPathComponent)
            .appendingPathComponent(tail)
    }
    return job.root
        .appendingPathComponent(backup.safeFolderName)
        .appendingPathComponent(tail)
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
    // Annotations travel with their page, but the outline hangs off the document and
    // would be left behind. For a book that is its table of contents.
    if let outline = doc.outlineRoot {
        clean.outlineRoot = copiedOutline(outline, from: doc, to: clean)
    }
    return clean
}

/// Rebuilds an outline against the new document, remapping each destination by page
/// index. A destination still pointing at the old document's page would be dead.
private func copiedOutline(_ node: PDFOutline, from source: PDFDocument,
                           to target: PDFDocument) -> PDFOutline {
    let copy = PDFOutline()
    copy.label = node.label
    if let destination = node.destination, let page = destination.page {
        let index = source.index(for: page)
        if index != NSNotFound, let moved = target.page(at: index) {
            copy.destination = PDFDestination(page: moved, at: destination.point)
        }
    } else if let action = node.action {
        // A link out of the document needs no remapping.
        copy.action = action
    }
    for position in 0..<node.numberOfChildren {
        guard let child = node.child(at: position) else { continue }
        copy.insertChild(copiedOutline(child, from: source, to: target),
                         at: copy.numberOfChildren)
    }
    return copy
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
/// `trashed` holds `Job.key`s to move to the Trash instead of renaming, and `moves` maps
/// a key to a folder the file should be sent to instead.
public func process(
    jobs: [Job],
    options: Options,
    overrides: [String: String] = [:],
    trashed: Set<String> = [],
    moves: [String: URL] = [:],
    progress: ((Int, Int, String) -> Void)? = nil
) -> [Item] {
    func run(_ job: Job) -> Item {
        if trashed.contains(job.key) { return moveToTrash(job, dryRun: options.dryRun) }
        if let folder = moves[job.key] {
            // The name it would have had anyway, unless one was typed.
            let planned = overrides[job.key].map(sanitizedFilename)
                ?? process(job: job, options: dryRunning(options), overrideName: nil).destinationName
            return moveFile(job, to: folder, named: planned, dryRun: options.dryRun)
        }
        return process(job: job, options: options, overrideName: overrides[job.key])
    }

    /// Used only to work out a name without touching anything.
    func dryRunning(_ options: Options) -> Options {
        var copy = options
        copy.dryRun = true
        return copy
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

/// Moves a file to a folder of the user's choosing, under the name it would have been
/// given anyway. The folder is created if it does not exist yet.
///
/// No backup is taken: nothing is being rewritten or destroyed, the file is simply
/// somewhere else, and a copy left behind would defeat the point of moving it.
public func moveFile(_ job: Job, to folder: URL, named name: String, dryRun: Bool) -> Item {
    let source = job.file
    let target = folder.appendingPathComponent(name)
    func item(_ destination: URL, _ status: Status, _ message: String = "") -> Item {
        Item(root: job.root, source: source, destination: destination,
             status: status, message: message)
    }
    guard !dryRun else {
        return item(availableURL(target, ignoring: source), .moved, "will move to \(folder.path)")
    }
    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = availableURL(target, ignoring: source)
        if destination.standardizedFileURL != source.standardizedFileURL {
            try fm.moveItem(at: source, to: destination)
        }
        var done = item(destination, .moved, "moved to \(folder.path)")
        done.carriedOut = true
        return done
    } catch {
        return item(source, .failed, "could not move: \(error.localizedDescription)")
    }
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
        var done = item((moved as URL?) ?? source, .trashed, "moved to the Trash")
        done.carriedOut = true
        return done
    } catch {
        return item(source, .failed, "could not move to the Trash: \(error.localizedDescription)")
    }
}

public func process(job: Job, options: Options, overrideName: String? = nil) -> Item {
    let source = job.file
    let directory = source.deletingLastPathComponent()

    var facts: (metadata: Date?, modified: Date?) = (nil, nil)
    var size: Int?
    var pages: Int?
    var info: [String: String] = [:]
    func item(_ destination: URL, _ status: Status, _ message: String = "") -> Item {
        Item(root: job.root, source: source, destination: destination,
             status: status, message: message,
             metadataDate: facts.metadata, modifiedDate: facts.modified,
             byteCount: size, pageCount: pages, documentInfo: info)
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
    // Readable even while locked: the page tree is not encrypted, only its contents.
    pages = doc.pageCount
    if unlocked, let attributes = doc.documentAttributes {
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute,
                    .creatorAttribute, .producerAttribute, .keywordsAttribute] {
            guard let value = attributes[key] else { continue }
            let text = (value as? String) ?? (value as? [String])?.joined(separator: ", ") ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { info[key.rawValue] = trimmed }
        }
    }

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
        let backup = availableURL(backupURL(for: job, options.backup))
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
        var done = item(destination, status)
        done.carriedOut = true
        return done
    }

    // No backup: the original is consumed. Write the replacement to a temporary file
    // first so a failure part-way through never leaves the folder without the document.
    let destination = availableURL(directory.appendingPathComponent(newName), ignoring: source)
    var scratch: URL?
    do {
        if status == .decrypted {
            let temp = directory.appendingPathComponent(".pdfhammer-\(UUID().uuidString).pdf")
            scratch = temp
            guard let clean = decryptedCopy(of: doc), clean.write(to: temp) else {
                try? fm.removeItem(at: temp)
                return item(source, .failed, "could not write the copy; original left untouched")
            }
            // The original is never deleted before its replacement exists. Removing it
            // first meant that a move failing for any reason left the only copy of the
            // document in a hidden temporary file the error message did not even name.
            if sameFile(destination, source) {
                _ = try fm.replaceItemAt(source, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
                do {
                    try fm.removeItem(at: source)
                } catch {
                    var done = item(destination, status,
                                    "written, but the original could not be removed")
                    done.carriedOut = true
                    return done
                }
            }
        } else if destination.standardizedFileURL != source.standardizedFileURL {
            try fm.moveItem(at: source, to: destination)
        }
    } catch {
        // Whatever failed, the original is still where it was, and the half-written copy
        // does not get to linger as a hidden file nobody knows to look for.
        if let scratch { try? fm.removeItem(at: scratch) }
        return item(source, .failed, "\(error.localizedDescription); the original is untouched")
    }
    var done = item(destination, status)
    done.carriedOut = true
    return done
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
