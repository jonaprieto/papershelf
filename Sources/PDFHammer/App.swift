import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

/// Window chrome the menu bar needs to reach. The split view draws its own sidebar
/// button, so the menu supplies only the shortcut.
@MainActor
final class Chrome: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// Set by the window so the menu can reach the runner without owning it.
    @Published var undo: () -> Void = {}
    @Published var canUndo = false
    /// Hides everything that is about deciding, leaving the page.
    @AppStorage("readingMode") var reading = false
    /// Shared with the inspector through the same keys, so the menu can reach them.
    @AppStorage("notesShown") var notesShown = false
    @AppStorage("contentsShown") var contentsShown = false

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}

@main
struct PDFHammerApp: App {
    @StateObject private var chrome = Chrome()

    var body: some Scene {
        Window("PDF Hammer", id: "main") {
            ContentView(chrome: chrome)
        }
        Settings { SettingsView() }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: chrome.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!chrome.canUndo)
            }
            CommandGroup(after: .sidebar) {
                Button(chrome.reading ? "Leave Reading Mode" : "Reading Mode") {
                    chrome.reading.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(chrome.notesShown ? "Hide Notes" : "Show Notes") {
                    chrome.notesShown.toggle()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(chrome.contentsShown ? "Hide Contents" : "Show Contents") {
                    chrome.contentsShown.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Toggle Sidebar", action: chrome.toggleSidebar)
                    .keyboardShortcut("b", modifiers: .command)
            }
        }
    }
}

// MARK: - Covers

/// Renders and caches first-page thumbnails. Nothing is drawn until a card asks for it,
/// so a shelf of thousands costs only what is on screen.
@MainActor
final class Covers: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    /// Bumped when a render lands, to redraw the cards waiting on one.
    @Published private(set) var revision = 0

    /// Four at a time: enough to fill a scroll, few enough to leave the UI responsive.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() { cache.countLimit = 400 }

    func cover(for item: Item, passwords: [String], height: CGFloat) -> NSImage? {
        if let hit = cache.object(forKey: item.key as NSString) { return hit }
        guard !inFlight.contains(item.key) else { return nil }
        inFlight.insert(item.key)

        let url = item.currentURL
        let key = item.key
        Covers.queue.addOperation { [weak self] in
            let image = Covers.render(url, passwords: passwords, height: height)
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(key)
                guard let image else { return }
                self.cache.setObject(image, forKey: key as NSString)
                self.revision &+= 1
            }
        }
        return nil
    }

    func forget() {
        cache.removeAllObjects()
        inFlight.removeAll()
        revision &+= 1
    }

    private nonisolated static func render(_ url: URL, passwords: [String], height: CGFloat) -> NSImage? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked {
            for password in passwords where document.unlock(withPassword: password) { break }
        }
        guard let page = document.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.height > 0 else { return nil }
        let width = max(1, box.width * (height / box.height))
        return page.thumbnail(of: NSSize(width: width, height: height), for: .mediaBox)
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case list, catalogue, bibliography, duplicates
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .catalogue: return "Catalogue"
        case .bibliography: return "BibTeX"
        case .duplicates: return "Duplicates"
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .catalogue: return "square.grid.2x2"
        case .bibliography: return "text.quote"
        case .duplicates: return "doc.on.doc"
        }
    }
}

// MARK: - Runner

/// Coalesces the scan callback, which fires once per directory read and would otherwise
/// spawn thousands of main-actor hops on a deep tree.
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: UInt64
    private var last: UInt64 = 0

    init(milliseconds: UInt64) { interval = milliseconds * 1_000_000 }

    func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- last >= interval else { return false }
        last = now
        return true
    }
}

/// What the reviewer decided about one file. Absent means still to review.
enum Decision: Equatable {
    case confirmed(String)
    /// Already carried out on disk, on its own, ahead of the batch.
    case applied
    case skipped
    /// Marked for the Trash. Nothing happens until Apply, so this is undoable by
    /// reopening the file.
    case deleted
    /// Headed for another folder, under the name it would have been given anyway.
    case moveTo(URL)
}

@MainActor
final class Runner: ObservableObject {
    enum Phase: Equatable { case idle, scanning, processing }

    @Published private(set) var results: [Item] = []
    @Published var phase: Phase = .idle
    @Published var done = 0
    @Published var total = 0
    @Published var found = 0
    @Published var current = ""
    @Published var lastRunWasDry = true
    /// Snapshot of the inputs the current results were produced from.
    @Published var fingerprint = ""
    /// Keyed by `Item.key`.
    @Published private(set) var decisions: [String: Decision] = [:]

    // Derived state is cached rather than recomputed. A view body runs constantly, and
    // filtering a list of a hundred thousand results on every pass is what turns a large
    // folder from slow into unusable.
    @Published private(set) var tree: [Node] = []
    @Published private(set) var statusCounts: [(Status, Int)] = []
    @Published private(set) var bib: [BibEntry] = []
    @Published private(set) var bibByItem: [String: BibEntry] = [:]
    private var bibStale = true
    @Published private(set) var log: [LogEntry] = []
    /// One entry per undoable step. A step can touch many files, so each holds the
    /// decisions exactly as they were before it ran.
    private var undoStack: [[(key: String, decision: Decision?)]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    @Published private(set) var confirmedCount = 0
    @Published private(set) var appliedCount = 0
    /// Bumped whenever the suggested names change without the list itself changing.
    @Published private(set) var revision = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var deletedCount = 0
    @Published private(set) var movedCount = 0

    /// Indices into `results`, grouped by containing folder, so folder questions cost the
    /// size of one folder rather than a scan of everything.
    private var byFolder: [String: [Int]] = [:]
    private var indexByKey: [String: Int] = [:]
    private var ancestorsByKey: [String: [String]] = [:]
    /// Only ever sweeps forward, so walking the whole stack is linear overall rather than
    /// quadratic. Reopening a file earlier in the list pulls it back.
    private var cursor = 0

    @Published private(set) var duplicates: [DuplicateGroup] = []
    /// `Item.key` to the kind of duplicate it is, for the badge on a row or card.
    @Published private(set) var duplicateKind: [String: DuplicateGroup.Kind] = [:]
    @Published private(set) var findingDuplicates = false
    /// Whether a comparison has been run, so "none found" reads differently to "not asked".
    @Published private(set) var duplicatesChecked = false

    private var jobs: [Job] = []


    var busy: Bool { phase != .idle }
    var reviewed: Int { confirmedCount + appliedCount + skippedCount + deletedCount + movedCount }
    var pendingCount: Int { results.count - reviewed }
    var allReviewed: Bool { lastRunWasDry && !results.isEmpty && pendingCount == 0 }
    /// What a batch Apply would still touch. Files already applied are done.
    var actionable: Int { confirmedCount + deletedCount + movedCount }

    func decision(for item: Item) -> Decision? { decisions[item.key] }

    func item(_ key: String) -> Item? {
        indexByKey[key].map { results[$0] }
    }

    /// Node ids of the folders a file sits under, so the tree can open itself to it.
    func ancestors(of key: String) -> [String] { ancestorsByKey[key] ?? [] }

    /// Recomputes every suggested name under new rules, from dates already captured.
    /// Decisions are left alone: a confirmed name is the one the user chose, and it is
    /// still what Apply will use. Reopening a file picks up the new suggestion.
    func restyle(options: Options) {
        guard lastRunWasDry, !results.isEmpty else { return }
        let snapshot = results
        let known = guesses
        // Off the main actor: at ten thousand files this is most of a second, and it runs
        // on every rule toggle. Doing it here would freeze the window each time.
        Task.detached(priority: .userInitiated) { [self] in
            let restyled = PDFHammerCore.restyled(snapshot, options: options, known: known)
            await MainActor.run {
                // A newer run may have landed while this was working.
                guard self.results.count == snapshot.count, self.lastRunWasDry else { return }
                self.results = restyled
                self.refreshBib()
                self.revision += 1
            }
        }
    }

    /// The next file still waiting, from the cursor onwards, wrapping once.
    func nextPending() -> Item? {
        var index = cursor
        while index < results.count {
            if decisions[results[index].key] == nil {
                cursor = index
                return results[index]
            }
            index += 1
        }
        index = 0
        while index < min(cursor, results.count) {
            if decisions[results[index].key] == nil {
                cursor = index
                return results[index]
            }
            index += 1
        }
        return nil
    }

    func confirm(_ item: Item, as name: String) {
        remember([item.key])
        let final = sanitizedFilename(name)
        set(.confirmed(final), for: item.key)
        note(.confirmed, for: item, detail: final == item.destinationName ? "" : "as \(final)")
    }

    func skip(_ item: Item) {
        remember([item.key])
        set(.skipped, for: item.key)
        note(.skipped, for: item)
    }

    func markForDeletion(_ item: Item) {
        remember([item.key])
        set(.deleted, for: item.key)
        note(.trashed, for: item, detail: "marked")
    }

    func move(_ item: Item, to folder: URL) {
        remember([item.key])
        set(.moveTo(folder), for: item.key)
        note(.moved, for: item, detail: "marked for \(folder.path)")
    }

    /// Drops every file that came from a source, in place. A rescan would give the same
    /// answer at the cost of walking the disk again, and everything downstream, the tree,
    /// the counts, the duplicates and the entries, is rebuilt from the results anyway.
    func removeSource(_ root: URL, fingerprint: String) {
        let path = root.resolvingSymlinksInPath().path
        func belongs(_ url: URL) -> Bool {
            let candidate = url.resolvingSymlinksInPath().path
            return candidate == path || candidate.hasPrefix(path + "/")
        }

        let survivors = results.filter { !belongs($0.root) }
        guard survivors.count != results.count else {
            self.fingerprint = fingerprint
            return
        }

        let gone = Set(results.filter { belongs($0.root) }.map(\.key))
        for key in gone {
            set(nil, for: key)
            guesses[key] = nil
        }
        jobs.removeAll { belongs($0.root) }

        // Groups can lose members, and one survivor is no longer a duplicate of anything.
        duplicates = duplicates.compactMap { group in
            var trimmed = group
            trimmed.items.removeAll { gone.contains($0.key) }
            return trimmed.items.count > 1 ? trimmed : nil
        }
        duplicateKind = Dictionary(uniqueKeysWithValues: duplicates.flatMap { group in
            group.items.map { ($0.key, group.kind) }
        })

        finish(survivors, keepingDecisions: true)
        // The results now match the smaller selection, so the preview is current again.
        self.fingerprint = fingerprint
    }


    func reopen(_ item: Item) {
        remember([item.key])
        set(nil, for: item.key)
        if let index = results.firstIndex(where: { $0.key == item.key }) {
            cursor = min(cursor, index)
        }
    }

    private func set(_ decision: Decision?, for key: String) {
        tally(decisions[key], by: -1)
        decisions[key] = decision
        tally(decision, by: 1)
    }

    /// Records what the given keys looked like, so one step can be taken back.
    private func remember(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        undoStack.append(keys.map { (key: $0, decision: decisions[$0]) })
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        for (key, decision) in step { set(decision, for: key) }
        note(.edited, subject: "\(step.count) file\(step.count == 1 ? "" : "s")", detail: "undone")
    }

    func note(_ kind: LogEntry.Kind, subject: String, detail: String = "") {
        log.append(LogEntry(kind: kind, subject: subject, detail: detail))
    }

    private func note(_ kind: LogEntry.Kind, for item: Item, detail: String = "") {
        note(kind, subject: item.relativePath, detail: detail)
    }

    private func tally(_ decision: Decision?, by delta: Int) {
        switch decision {
        case .confirmed: confirmedCount += delta
        case .applied: appliedCount += delta
        case .skipped: skippedCount += delta
        case .deleted: deletedCount += delta
        case .moveTo: movedCount += delta
        case nil: break
        }
    }

    /// Accepts every suggestion still waiting, for when reviewing thousands of files one
    /// at a time is not what you came here for.
    func confirmAllPending() {
        remember(results.filter { decisions[$0.key] == nil }.map(\.key))
        note(.confirmed, subject: "\(pendingCount) pending", detail: "all remaining")
        for item in results where decisions[item.key] == nil {
            decisions[item.key] = .confirmed(item.destinationName)
            confirmedCount += 1
        }
        cursor = results.count
    }

    func skipFolder(of item: Item) {
        let scope = (byFolder[folderPath(of: item)] ?? []).map { results[$0].key }
        remember(scope.filter { decisions[$0] == nil })
        note(.skipped, subject: folderPath(of: item), detail: "rest of folder")
        for index in byFolder[folderPath(of: item)] ?? [] where decisions[results[index].key] == nil {
            decisions[results[index].key] = .skipped
            skippedCount += 1
        }
    }

    func pendingInFolder(of item: Item) -> Int {
        (byFolder[folderPath(of: item)] ?? []).reduce(0) {
            $0 + (decisions[results[$1].key] == nil ? 1 : 0)
        }
    }

    /// Carries out one file right now instead of queueing it. Runs on the main actor:
    /// it is a single document, and doing it inline keeps the result and the row in step.
    func applyNow(_ item: Item, as name: String, options: Options) {
        guard let job = jobs.first(where: { $0.key == item.key }) else { return }
        let done = decisions[item.key] == .deleted
            ? moveToTrash(job, dryRun: false)
            : process(job: job, options: options, overrideName: name)
        replace(item.key, with: done)
        set(.applied, for: item.key)
        note(kind(for: done.status), for: item, detail: "-> \(done.destinationName)")
    }

    /// Updates one row in place. The tree holds keys, so it needs no rebuilding.
    private func replace(_ key: String, with item: Item) {
        guard let index = indexByKey[key] else { return }
        // The file may have moved, so anything read from the old path is now stale.
        excerpts[key] = nil
        textCache[key] = nil
        let previous = results[index].status
        results[index] = item
        refreshBib()
        revision += 1
        guard previous != item.status else { return }
        var counts = Dictionary(uniqueKeysWithValues: statusCounts)
        counts[previous, default: 1] -= 1
        counts[item.status, default: 0] += 1
        statusCounts = Status.allCases.compactMap { status in
            counts[status].flatMap { $0 > 0 ? (status, $0) : nil }
        }
    }

    var identicalExtras: Int {
        duplicates.filter { $0.kind == .identical }.reduce(0) { $0 + $1.extras.count }
    }

    /// Drops everything held from previous runs.
    func reset() {
        begin(fingerprint: "", dry: true)
        phase = .idle
        clearRunCache()
    }

    /// Marks the entries out of date. They are not rebuilt here: most runs never open
    /// the bibliography, and building them for a large collection on every rename is
    /// work nobody asked for.
    private func refreshBib() { bibStale = true }

    /// Builds the entries if anything has moved since they were last needed.
    @Published private(set) var searchText = ""
    @Published private(set) var searching = false
    /// Nil when no query is active, so the views can tell "no filter" from "no matches".
    @Published private(set) var matchingKeys: Set<String>?
    /// Opening text, read once per file and only when a text query has asked for it.
    private var textCache: [String: String] = [:]

    /// The searchable projection of every file, built once per result set. Rebuilding it
    /// per keystroke was most of what a metadata search cost.
    private var projections: [Searchable] = []
    private var projectionsIncludeText = false

    private func buildProjections(includingText: Bool) {
        projections = results.map {
            Searchable(item: $0, text: includingText ? textCache[$0.key] : nil)
        }
        projectionsIncludeText = includingText
    }

    func search(_ text: String, passwords: [String]) {
        searchText = text
        let query = Query(text)
        guard !query.isEmpty else {
            matchingKeys = nil
            return
        }

        guard query.needsText else {
            if projections.count != results.count { buildProjections(includingText: projectionsIncludeText) }
            let prepared = PreparedQuery(query)
            matchingKeys = Set(zip(results, projections)
                .filter { matches($0.1, prepared) }
                .map(\.0.key))
            return
        }

        // A text query has to read the documents. Cached, concurrent, and off the main
        // thread, because this is the one search that costs real work.
        searching = true
        let snapshot = results
        let cached = textCache
        Task.detached(priority: .userInitiated) { [self] in
            var fresh: [String: String] = [:]
            let lock = NSLock()
            let missing = snapshot.filter { cached[$0.key] == nil }
            if !missing.isEmpty {
                DispatchQueue.concurrentPerform(iterations: missing.count) { index in
                    let item = missing[index]
                    let text = openingText(of: item.currentURL, passwords: passwords, pages: 6)
                    lock.lock()
                    fresh[item.key] = text
                    lock.unlock()
                }
            }
            await MainActor.run {
                self.textCache.merge(fresh) { _, new in new }
                guard self.searchText == text else { return }
                self.buildProjections(includingText: true)
                let prepared = PreparedQuery(query)
                self.matchingKeys = Set(zip(self.results, self.projections)
                    .filter { matches($0.1, prepared) }
                    .map(\.0.key))
                self.searching = false
            }
        }
    }

    @Published private(set) var excerpts: [String: String] = [:]

    /// Reads the opening words of one file, for the panel under the actions. One file at
    /// a time and cached, so browsing costs a single read per file at most.
    func loadExcerpt(for item: Item, passwords: [String]) {
        guard excerpts[item.key] == nil, textCache[item.key] == nil else { return }
        let source = item.currentURL
        let key = item.key
        Task.detached(priority: .utility) { [self] in
            let text = openingText(of: source, passwords: passwords, pages: 2)
            let squeezed = text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            await MainActor.run { self.excerpts[key] = squeezed }
        }
    }

    func excerpt(for item: Item) -> String? {
        if let ready = excerpts[item.key] { return ready.isEmpty ? nil : ready }
        if let cached = textCache[item.key] {
            let squeezed = cached.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return squeezed.isEmpty ? nil : squeezed
        }
        return nil
    }

    /// Re-orders in place. Everything derived hangs off the results, so the tree, the
    /// folder index and the cursor are rebuilt from the new order.
    func sortResults(by order: ItemSort, descending: Bool) {
        guard !results.isEmpty else { return }
        finish(sorted(results, by: order, descending: descending), keepingDecisions: true)
    }

    /// The entry type the next rebuild should use.
    var bibType: BibType = .book {
        didSet { if bibType != oldValue { bibStale = true } }
    }

    func ensureBib() {
        guard bibStale else { return }
        bibStale = false
        bib = bibEntries(for: results, known: guesses, type: bibType)
        bibByItem = Dictionary(uniqueKeysWithValues: bib.map { ($0.itemKey, $0) })
    }

    func findDuplicates(passwords: [String] = []) {
        guard !results.isEmpty, !findingDuplicates else { return }
        findingDuplicates = true
        let snapshot = results
        Task.detached(priority: .userInitiated) { [self] in
            let found = duplicateGroups(in: snapshot, passwords: passwords)
            await MainActor.run {
                self.duplicates = found
                self.duplicateKind = Dictionary(
                    uniqueKeysWithValues: found.flatMap { group in
                        group.items.map { ($0.key, group.kind) }
                    }
                )
                self.findingDuplicates = false
                self.duplicatesChecked = true
            }
        }
    }

    /// Marks the spare copies of byte-identical files for the Trash, keeping the best of
    /// each. Only identical groups: a likely match is a guess, and guesses do not get to
    /// delete a book on their own.
    /// Promotes a different copy to keeper within its group.
    func keep(_ item: Item, inGroup id: String) {
        guard let index = duplicates.firstIndex(where: { $0.id == id }) else { return }
        duplicates[index].keep(item.key)
    }

    /// Marks the spare copies of one group, whichever kind it is. Doing this for a whole
    /// kind at once is only offered for identical groups; here the choice is per group,
    /// having looked at it.
    func trashExtras(of id: String) {
        guard let group = duplicates.first(where: { $0.id == id }) else { return }
        for extra in group.extras where decisions[extra.key] != .deleted {
            set(.deleted, for: extra.key)
        }
    }

    func markIdenticalExtras() {
        for group in duplicates where group.kind == .identical {
            for extra in group.extras where decisions[extra.key] == nil {
                decisions[extra.key] = .deleted
                deletedCount += 1
            }
        }
    }

    /// What the model has said about a file, by `Item.key`. Keeps author and year, which
    /// a filename cannot carry, so a bibliography can use them.
    @Published private(set) var guesses: [String: BookGuess] = [:]
    @Published private(set) var thinking: Set<String> = []
    @Published var aiError: String?

    /// Asks the model what a file is and puts the answer in as the suggested name.
    /// Nothing is decided: the suggestion still has to be confirmed like any other.
    func identify(_ item: Item, client: AIClient, passwords: [String], rules: NameRules) async {
        guard !thinking.contains(item.key) else { return }
        thinking.insert(item.key)
        defer { thinking.remove(item.key) }

        let source = item.currentURL
        let excerpt = await Task.detached(priority: .userInitiated) {
            openingText(of: source, passwords: passwords)
        }.value

        do {
            let guess = try await client.identify(filename: item.sourceName, excerpt: excerpt)
            guesses[item.key] = guess
            let name = filename(for: guess, rules: rules)
            guard !name.isEmpty, let index = indexByKey[item.key] else { return }
            var updated = results[index]
            updated.destination = updated.source.deletingLastPathComponent()
                .appendingPathComponent(name)
            replace(item.key, with: updated)
        } catch {
            aiError = error.localizedDescription
        }
    }

    func isThinking(_ item: Item) -> Bool { thinking.contains(item.key) }

    /// Runs over everything still undecided, a few at a time so one slow reply does not
    /// hold up the rest and the service is not hit with hundreds at once.
    func identifyPending(client: AIClient, passwords: [String], rules: NameRules) async {
        let queue = results.filter { decisions[$0.key] == nil }
        var index = 0
        while index < queue.count {
            let slice = queue[index..<min(index + 4, queue.count)]
            await withTaskGroup(of: Void.self) { group in
                for item in slice {
                    group.addTask { @MainActor in
                        await self.identify(item, client: client, passwords: passwords, rules: rules)
                    }
                }
            }
            index += 4
        }
    }

    /// True while what is on screen came from the last launch rather than from a scan.
    @Published private(set) var showingCached = false

    /// Puts the previous run on screen at once. Nothing here is a claim about the present:
    /// it is what was true last time, shown so the window is not empty while the disk is
    /// read, and replaced the moment a real scan lands.
    @discardableResult
    func showCached(fingerprint: String) -> Bool {
        guard results.isEmpty, let cache = loadRunCache(matching: fingerprint) else { return false }
        begin(fingerprint: fingerprint, dry: true)
        showingCached = true
        finish(cache.items)
        phase = .idle
        note(.previewed, subject: "\(cache.items.count) files",
             detail: "from \(cache.savedAt.formatted(date: .abbreviated, time: .shortened))")
        return true
    }

    @Published private(set) var absorbing = false
    /// How many files the last absorb brought in, for the status strip to report.
    @Published private(set) var lastAbsorbed = 0

    /// Folds changes on disk into the current results without starting over.
    ///
    /// Only new files are opened; ones already known keep the item they have, and with it
    /// any decision made about them. Files that have gone are dropped. A full rescan would
    /// be correct too, but it would reopen every PDF and discard the review in progress,
    /// which is the opposite of what a watcher is for.
    func absorbChanges(roots: [URL], options: Options, fingerprint: String) async {
        guard !busy, !absorbing, lastRunWasDry, !results.isEmpty else { return }
        absorbing = true
        defer { absorbing = false }

        let known = Dictionary(uniqueKeysWithValues: results.map { ($0.key, $0) })
        let backup = options.backup
        let recursive = options.recursive
        let found = await Task.detached(priority: .utility) {
            collectJobs(roots: roots, recursive: recursive, backup: backup)
        }.value

        let fresh = found.filter { known[$0.key] == nil }
        let present = Set(found.map(\.key))
        let vanished = results.filter { !present.contains($0.key) }.map(\.key)
        guard !fresh.isEmpty || !vanished.isEmpty else { return }

        var arrived: [String: Item] = [:]
        if !fresh.isEmpty {
            total = fresh.count
            done = 0
            let previewed = await Task.detached(priority: .utility) {
                process(jobs: fresh, options: options)
            }.value
            arrived = Dictionary(uniqueKeysWithValues: previewed.map { ($0.key, $0) })
            note(.scanned, subject: "\(fresh.count) new file\(fresh.count == 1 ? "" : "s")",
                 detail: "picked up while watching")
        }
        if !vanished.isEmpty {
            note(.vanished, subject: "\(vanished.count) file\(vanished.count == 1 ? "" : "s")",
                 detail: "no longer on disk")
        }

        // Rebuilt in scan order, so a new file lands where it belongs rather than at the end.
        let merged = found.compactMap { known[$0.key] ?? arrived[$0.key] }
        for key in vanished {
            set(nil, for: key)
            guesses[key] = nil
        }
        jobs = found
        lastAbsorbed = fresh.count

        let derived = await Task.detached(priority: .utility) { Runner.derive(merged) }.value
        finish(merged, keepingDecisions: true, derived: derived)
        self.fingerprint = fingerprint
        saveRunCache(RunCache(fingerprint: fingerprint, items: merged))
    }

    func preview(roots: [URL], options: Options, fingerprint: String) {
        let wasCached = showingCached
        begin(fingerprint: fingerprint, dry: true)
        // Keep the old rows visible while the new ones are being worked out, so a refresh
        // does not blank the window.
        showingCached = wasCached

        Task.detached(priority: .userInitiated) { [self] in
            let throttle = Throttle(milliseconds: 80)
            let found = collectJobs(roots: roots, recursive: options.recursive) { directory, count in
                guard throttle.allow() else { return }
                Task { @MainActor in
                    self.current = directory
                    self.found = count
                }
            }
            await MainActor.run {
                self.jobs = found
                self.phase = .processing
                self.total = found.count
                self.found = found.count
                self.current = ""
            }
            let out = process(jobs: found, options: options, progress: self.report)
            let derived = Runner.derive(out)
            saveRunCache(RunCache(fingerprint: fingerprint, items: out))
            await MainActor.run {
                self.showingCached = false
                self.finish(out, derived: derived)
            }
        }
    }

    /// Runs the reviewed plan. Skipped files are dropped, confirmed names are passed
    /// through verbatim, so the result matches the preview line for line.
    func apply(options: Options) {
        let decisions = self.decisions
        // Skipped files are left alone, and anything already applied is finished.
        let queue = jobs.filter {
            let decision = decisions[$0.key]
            return decision != .skipped && decision != .applied
        }
        var overrides: [String: String] = [:]
        var trashed: Set<String> = []
        var moves: [String: URL] = [:]
        for (key, decision) in decisions {
            switch decision {
            case .confirmed(let name): overrides[key] = name
            case .deleted: trashed.insert(key)
            case .moveTo(let folder): moves[key] = folder
            case .skipped, .applied, nil: break
            }
        }

        begin(fingerprint: fingerprint, dry: false)
        total = queue.count

        Task.detached(priority: .userInitiated) { [self] in
            await MainActor.run { self.phase = .processing }
            let out = process(jobs: queue, options: options, overrides: overrides,
                              trashed: trashed, moves: moves, progress: self.report)
            let derived = Runner.derive(out)
            await MainActor.run {
                for item in out { self.note(self.kind(for: item.status), for: item,
                                            detail: "-> \(item.destinationName)") }
                self.finish(out, derived: derived)
            }
        }
    }

    private func kind(for status: Status) -> LogEntry.Kind {
        switch status {
        case .decrypted: return .decrypted
        case .renamed: return .renamed
        case .moved: return .moved
        case .encrypted: return .decrypted
        case .trashed: return .trashed
        case .failed: return .failed
        case .locked: return .renamed
        }
    }

    private func begin(fingerprint: String, dry: Bool) {
        phase = dry ? .scanning : .processing
        showingCached = false
        results = []
        tree = []
        statusCounts = []
        byFolder = [:]
        indexByKey = [:]
        ancestorsByKey = [:]
        duplicates = []
        duplicateKind = [:]
        duplicatesChecked = false
        guesses = [:]
        matchingKeys = nil
        searchText = ""
        textCache = [:]
        excerpts = [:]
        projections = []
        projectionsIncludeText = false
        decisions = [:]
        confirmedCount = 0
        appliedCount = 0
        skippedCount = 0
        deletedCount = 0
        movedCount = 0
        cursor = 0
        done = 0
        total = 0
        found = 0
        current = ""
        lastRunWasDry = dry
        self.fingerprint = fingerprint
    }

    private nonisolated func report(done: Int, total: Int, name: String) {
        Task { @MainActor in
            self.done = done
            self.total = total
            self.current = name
        }
    }

    /// Everything derived from the results is built once, here.
    /// Everything derived from a result set, computed together so it can be built away
    /// from the main actor.
    struct Derived: Sendable {
        let tree: [Node]
        let statusCounts: [(Status, Int)]
        let byFolder: [String: [Int]]
        let indexByKey: [String: Int]
        let ancestorsByKey: [String: [String]]
    }

    /// Building the tree and the indexes is linear in the collection, which at ten
    /// thousand files is long enough to be felt if it happens on the main actor.
    nonisolated static func derive(_ out: [Item]) -> Derived {
        let tree = buildTree(out)

        var counts: [Status: Int] = [:]
        var folders: [String: [Int]] = [:]
        var keys: [String: Int] = [:]
        for (index, item) in out.enumerated() {
            counts[item.status, default: 0] += 1
            folders[folderPath(of: item), default: []].append(index)
            keys[item.key] = index
        }

        var ancestors: [String: [String]] = [:]
        func walk(_ nodes: [Node], path: [String]) {
            for node in nodes {
                if let key = node.itemKey {
                    ancestors[key] = path
                } else {
                    walk(node.children ?? [], path: path + [node.id])
                }
            }
        }
        walk(tree, path: [])

        return Derived(
            tree: tree,
            statusCounts: Status.allCases.compactMap { status in counts[status].map { (status, $0) } },
            byFolder: folders,
            indexByKey: keys,
            ancestorsByKey: ancestors
        )
    }

    private func finish(_ out: [Item], keepingDecisions: Bool = false,
                        derived: Derived? = nil) {
        if !keepingDecisions { cursor = 0 }
        results = out
        let parts = derived ?? Runner.derive(out)
        tree = parts.tree
        statusCounts = parts.statusCounts
        byFolder = parts.byFolder
        indexByKey = parts.indexByKey
        ancestorsByKey = parts.ancestorsByKey
        refreshBib()
        projections = []

        done = out.count
        current = ""
        phase = .idle
    }
}

// MARK: - Rule labels

extension NameRules.Casing {
    var label: String {
        switch self {
        case .lowercase: return "lowercase"
        case .uppercase: return "UPPERCASE"
        case .unchanged: return "Leave as is"
        }
    }
}

extension NameRules.Separator {
    var label: String {
        switch self {
        case .keep: return "Keep as they are"
        case .dash: return "Dashes"
        case .underscore: return "Underscores"
        }
    }
}

// MARK: - Appearance

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// Resolves per appearance, so it follows both the system theme and an explicit
    /// override set on `NSApp.appearance`.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// MARK: - Content

struct ContentView: View {
    // Seeded empty on purpose: a real password does not belong in source. The sidebar
    // warns while the list is empty, and what you type is kept in UserDefaults.
    @AppStorage("passwords") private var passwordsText = ""
    @AppStorage("moveOriginals") private var moveOriginals = true
    @AppStorage("backupFolderName") private var backupFolderName = defaultBackupFolderName
    @AppStorage("backupCustomPath") private var backupCustomPath = ""
    @AppStorage("encryptOutput") private var encryptOutput = false
    /// Deliberately not @AppStorage: a password does not belong in a preferences plist.
    @State private var encryptPassword = ""
    @State private var choosingBackupFolder = false
    @State private var savingLog = false
    @State private var watcher: FolderWatcher?
    @StateObject private var palette = Palette()
    @AppStorage("useFolderNames") private var useFolderNames = true
    // On by default so a file nearly always ends up with a year in front of it.
    @AppStorage("useMetadataDate") private var useMetadataDate = true
    @AppStorage("useFileDate") private var useFileDate = false
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("ruleCasing") private var ruleCasing: NameRules.Casing = .lowercase
    @AppStorage("ruleSeparator") private var ruleSeparator: NameRules.Separator = .keep
    @AppStorage("ruleStripSymbols") private var ruleStripSymbols = false
    @AppStorage("ruleStripDiacritics") private var ruleStripDiacritics = false
    @AppStorage("ruleAsciiOnly") private var ruleAsciiOnly = false
    @AppStorage("ruleDropArticles") private var ruleDropArticles = false
    @AppStorage("ruleMaxLength") private var ruleMaxLength = 0
    @AppStorage("ruleDatePosition") private var ruleDatePosition: NameRules.DatePosition = .prefix
    @AppStorage("ruleDateFormat") private var ruleDateFormat: NameRules.DateFormat = .dashed

    @AppStorage("sources") private var storedSources = ""
    @AppStorage("autoPreview") private var autoPreview = true
    @AppStorage("watchSources") private var watchSources = true
    @AppStorage("viewMode") private var mode: ViewMode = .catalogue
    @AppStorage("aiModel") private var aiModel = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var aiUseEnvironment = true
    @AppStorage("autoIdentify") private var autoIdentify = false
    @AppStorage("bibLineWidth") private var bibLineWidth = 80
    @AppStorage("bibIndent") private var bibIndent = 2
    @AppStorage("bibAlign") private var bibAlign = true
    @AppStorage("bibDelimiter") private var bibDelimiter: BibStyle.Delimiter = .braces
    @AppStorage("bibTrailingComma") private var bibTrailingComma = true
    @AppStorage("bibBlankLines") private var bibBlankLines = true
    @AppStorage("bibSortFields") private var bibSortFields = false
    @AppStorage("bibDropAllCaps") private var bibDropAllCaps = false
    @AppStorage("bibOmitFile") private var bibOmitFile = true
    @AppStorage("bibType") private var bibType: BibType = .book
    @AppStorage("sidebarTab") private var sidebarTab: SidebarTab = .sources
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var modelsError: String?

    @StateObject private var runner = Runner()
    @StateObject private var covers = Covers()
    @State private var selection: [URL] = []
    @State private var importing = false
    /// Folders start closed. Only what has been opened, or opened for you to reach the
    /// selected file, is in here.
    @State private var expanded: Set<String> = []
    @State private var sizedWindow = false
    @State private var confirmingApply = false
    @State private var reviewing: String?
    @FocusState private var focusedPassword: Int?
    @ObservedObject var chrome: Chrome

    private var passwords: [String] { PasswordList.active(passwordsText) }
    private var passwordRows: [String] { PasswordList.rows(passwordsText) }

    /// Adds a row and puts the caret in it, so Add is one click and then typing.
    private func addPassword() {
        let added = PasswordList.addingRow(to: passwordsText)
        passwordsText = added.text
        DispatchQueue.main.async { focusedPassword = added.focus }
    }

    private func passwordBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let rows = PasswordList.rows(self.passwordsText)
                return rows.indices.contains(index) ? rows[index] : ""
            },
            set: { self.passwordsText = PasswordList.setting(index, to: $0, in: self.passwordsText) }
        )
    }

    private var backup: BackupSettings {
        BackupSettings(
            enabled: moveOriginals,
            folderName: backupFolderName,
            customLocation: backupCustomPath.isEmpty ? nil : URL(fileURLWithPath: backupCustomPath)
        )
    }

    private var aiClient: AIClient {
        AIClient(baseURL: aiBaseURL, model: aiModel,
                 apiKey: resolvedKey(useEnvironment: aiUseEnvironment))
    }

    private var aiReady: Bool { !aiClient.apiKey.isEmpty }

    /// The list is asked for once a key exists, and on demand after that.
    private func loadModels() {
        guard aiReady, !loadingModels else { return }
        loadingModels = true
        modelsError = nil
        let client = aiClient
        Task {
            do {
                availableModels = try await client.models()
            } catch {
                modelsError = error.localizedDescription
            }
            loadingModels = false
        }
    }

    private var rules: NameRules {
        NameRules(casing: ruleCasing, separator: ruleSeparator,
                  stripSymbols: ruleStripSymbols, stripDiacritics: ruleStripDiacritics,
                  asciiOnly: ruleAsciiOnly, dropLeadingArticles: ruleDropArticles,
                  maxLength: ruleMaxLength, datePosition: ruleDatePosition,
                  dateFormat: ruleDateFormat)
    }

    /// Exercises every rule at once, so the footer shows what each switch actually does.
    private static let sampleName = "Extracto Señor_Acme 66 (1)_23_08_2026.pdf"

    private func options(dryRun: Bool) -> Options {
        // Subfolders are always included; the preview shows exactly what that reaches.
        Options(passwords: passwords, recursive: true, dryRun: dryRun,
                backup: backup,
                encryption: EncryptionSettings(enabled: encryptOutput, password: encryptPassword),
                useFolderNames: useFolderNames,
                useMetadataDate: useMetadataDate, useFileDate: useFileDate, rules: rules)
    }

    /// What only a fresh scan can answer: which files there are, and which of them open.
    /// Change one of these and the preview no longer describes reality, so Apply is
    /// blocked until Preview runs again.
    private var fingerprint: String {
        [
            selection.map(\.path).joined(separator: "|"),
            passwords.joined(separator: "|"),
            "\(moveOriginals)", backup.safeFolderName, backupCustomPath,
            "\(encryptOutput)", encryptPassword.isEmpty ? "" : "set",
        ].joined(separator: "\u{1}")
    }

    /// What only changes the names. These are answered from dates already captured, so
    /// the list restyles itself instead of asking for another preview.
    private var namingFingerprint: String {
        [
            "\(useFolderNames)", "\(useMetadataDate)", "\(useFileDate)",
            ruleCasing.rawValue, ruleSeparator.rawValue,
            "\(ruleStripSymbols)", "\(ruleStripDiacritics)", "\(ruleAsciiOnly)",
            "\(ruleDropArticles)", "\(ruleMaxLength)",
            ruleDatePosition.rawValue, ruleDateFormat.rawValue,
        ].joined(separator: "\u{1}")
    }

    private var backupSummary: String {
        guard moveOriginals else {
            return "Originals are replaced in place. Nothing is kept and there is no undo."
        }
        if backupCustomPath.isEmpty {
            return "Moved to \(backup.safeFolderName)/ inside each source you pick, "
                 + "mirroring their subfolders."
        }
        return "Moved to the folder above, under one subfolder per source."
    }

    private var previewIsCurrent: Bool {
        !runner.results.isEmpty && runner.lastRunWasDry && runner.fingerprint == fingerprint
    }

    private func preview() {
        runner.preview(roots: selection, options: options(dryRun: true), fingerprint: fingerprint)
    }

    private func apply() {
        runner.apply(options: options(dryRun: false))
    }

    /// Anything irreversible gets a prompt: files headed for the Trash, or renames with
    /// no backup kept. A plain rename with backups on needs no ceremony.
    private func confirmApply() {
        if needsConfirmation { confirmingApply = true } else { apply() }
    }

    private var needsConfirmation: Bool {
        !moveOriginals || runner.deletedCount > 0
    }

    private var applyWarnings: [String] {
        var lines: [String] = []
        if runner.deletedCount > 0 {
            lines.append("\(runner.deletedCount) file\(runner.deletedCount == 1 ? "" : "s") "
                         + "will be moved to the Trash, recoverable from Finder.")
        }
        if !moveOriginals && runner.confirmedCount > 0 {
            lines.append("Move originals is off, so no copy of the other "
                         + "\(runner.confirmedCount) is kept. That cannot be undone.")
        }
        return lines
    }

    /// Applying needs a preview that still matches the settings, every file reviewed, and
    /// at least one of them kept.
    private var canApply: Bool {
        previewIsCurrent && runner.allReviewed && runner.actionable > 0 && !runner.busy
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $chrome.columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 310, max: 400)
        } detail: {
            ResultsPane(
                runner: runner,
                covers: covers,
                expanded: $expanded,
                selected: $reviewing,
                sourceCount: selection.count,
                previewIsCurrent: previewIsCurrent,
                passwords: passwords,
                reading: chrome.reading,
                watching: watchSources && !selection.isEmpty,
                palette: palette,
                rules: rules,
                chooseFiles: { importing = true },
                preview: preview,
                apply: confirmApply,
                applyOne: { item, name in
                    runner.applyNow(item, as: name, options: options(dryRun: false))
                }
            )
                .frame(minWidth: 700)
                .navigationTitle("PDF Hammer")
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        // Sidebar, browser, inspector and, when it is open, the notes rail.
        .frame(minWidth: chrome.notesShown ? 1180 : 1000, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .onChange(of: runner.canUndo) { _, can in chrome.canUndo = can }
        .onAppear {
            chrome.undo = { runner.undo() }
            chrome.canUndo = runner.canUndo
            sizeWindowOnFirstLaunch()
            NSApp.appearance = appearance.nsAppearance
            restoreSources()
            startWatching()
            if !selection.isEmpty {
                // Show last time's answer at once, then check the disk behind it.
                let hadCache = runner.showCached(fingerprint: fingerprint)
                if autoPreview || hadCache { preview() }
            }
            if aiReady && availableModels.isEmpty { loadModels() }
        }
        .onChange(of: appearance) { _, new in NSApp.appearance = new.nsAppearance }
        // Restyling is cheap but not free, so let a run of toggles settle first.
        .task(id: namingFingerprint) {
            guard !runner.results.isEmpty, runner.lastRunWasDry else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            runner.restyle(options: options(dryRun: true))
        }
        .confirmationDialog("Apply to \(runner.actionable) files?", isPresented: $confirmingApply) {
            Button("Apply", role: .destructive, action: apply)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyWarnings.joined(separator: "\n\n"))
        }
        .fileExporter(isPresented: $savingLog,
                      document: BibDocument(text: logText(runner.log)),
                      contentType: .plainText,
                      defaultFilename: "pdf-hammer-log.txt") { _ in }
        .fileImporter(
            isPresented: $choosingBackupFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { outcome in
            if case .success(let urls) = outcome, let folder = urls.first {
                backupCustomPath = folder.path
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .folder],
            allowsMultipleSelection: true
        ) { outcome in
            if case .success(let urls) = outcome { add(urls) }
        }
    }

    private var subtitle: String {
        switch runner.phase {
        case .scanning: return "Scanning, \(runner.found) PDF\(runner.found == 1 ? "" : "s") found"
        case .processing: return "Processing \(runner.done) of \(runner.total)"
        case .idle: break
        }
        guard !runner.results.isEmpty else {
            return selection.isEmpty ? "No sources" : "\(selection.count) source\(selection.count == 1 ? "" : "s")"
        }
        if !runner.lastRunWasDry { return "Applied to \(runner.results.count) files" }
        guard previewIsCurrent else { return "Preview is out of date" }
        return runner.pendingCount == 0
            ? "All \(runner.results.count) reviewed, ready to apply"
            : "\(runner.reviewed) of \(runner.results.count) reviewed"
    }

    // MARK: Sidebar

    /// An icon rail with one panel behind it, the way an editor does it. Everything used
    /// to be one long scroll of nine sections; this shows one job at a time.
    private var sidebar: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            Form {
                switch sidebarTab {
                case .sources: sourcesPanel
                case .passwords: passwordsPanel
                case .naming:
                    namingPanel
                    datesPanel
                case .files:
                    originalsPanel
                    runningPanel
                case .ai: aiPanel
                case .bibtex: bibtexPanel
                case .reading: readingPanel
                case .log: logPanel
                case .appearance: appearancePanel
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
    }

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                RailButton(tab: tab, isSelected: sidebarTab == tab) { sidebarTab = tab }
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 34, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tip("API key, model and endpoint", key: "⌘,")
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .background(.quaternary.opacity(0.25))
    }

    @ViewBuilder
    private var sourcesPanel: some View {
            Section("Sources") {
                if selection.isEmpty {
                    Text("Nothing selected")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(selection, id: \.self) { url in
                        SourceRow(url: url) { removeSource(url) }
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("Add folder or PDF", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                if !selection.isEmpty || !runner.results.isEmpty {
                    Button(role: .destructive, action: forgetEverything) {
                        Label("Forget sources and cached covers", systemImage: "trash")
                    }
                    .buttonStyle(.link)
                    .tip("Clears the selection, the results and the thumbnails")
                }
            }
    }


    @ViewBuilder
    private var passwordsPanel: some View {
            Section {
                ForEach(Array(passwordRows.enumerated()), id: \.offset) { index, _ in
                    HStack(spacing: 6) {
                        // Without labelsHidden the Form treats the string as a left-hand
                        // label and squeezes the field into the value column.
                        TextField("", text: passwordBinding(index), prompt: Text("Password"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .focused($focusedPassword, equals: index)
                            .onSubmit(addPassword)
                        Button {
                            passwordsText = PasswordList.removing(index, from: passwordsText)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .tip("Remove this password")
                        .help("Remove this password")
                        .accessibilityLabel("Remove password \(index + 1)")
                    }
                }
                Button(action: addPassword) {
                    Label("Add password", systemImage: "plus.circle")
                }
                .tip("Another password to try, in order")
                .buttonStyle(.link)
            } header: {
                Text("Passwords")
            } footer: {
                if passwords.isEmpty {
                    Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                         text: "No passwords set. Encrypted files will be renamed but stay locked.",
                         size: .caption)
                } else {
                    Text("Tried in order, top to bottom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }


    @ViewBuilder
    private var namingPanel: some View {
            Section {
                Picker("Case", selection: $ruleCasing) {
                    ForEach(NameRules.Casing.allCases) { Text($0.label).tag($0) }
                }
                .help("Applied to the whole name, date aside")
                Picker("Separators", selection: $ruleSeparator) {
                    ForEach(NameRules.Separator.allCases) { Text($0.label).tag($0) }
                }
                .tip("How runs of spaces, dashes and underscores are written")
                Toggle("Remove symbols", isOn: $ruleStripSymbols)
                    .tip("Punctuation becomes a separator: report (1)! reads report-1")
                Toggle("Remove accents", isOn: $ruleStripDiacritics)
                    .help("señor becomes senor. Separate from Remove symbols, since ñ is a letter")
                Toggle("ASCII only", isOn: $ruleAsciiOnly)
                    .tip("Non-ASCII becomes a separator, so words stay apart")
                Toggle("Drop a leading The, A, El…", isOn: $ruleDropArticles)
                    .help("So a shelf sorts by what the book is called rather than by its article")
                Picker("Date goes", selection: $ruleDatePosition) {
                    ForEach(NameRules.DatePosition.allCases) { Text($0.label).tag($0) }
                }
                .help("Whether the date leads the name or trails it")
                Picker("Date looks like", selection: $ruleDateFormat) {
                    ForEach(NameRules.DateFormat.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Max length") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { Double(ruleMaxLength) },
                                              set: { ruleMaxLength = Int($0) }),
                               in: 0...120, step: 5)
                        Text(ruleMaxLength == 0 ? "off" : "\(ruleMaxLength)")
                            .monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                    }
                }
                .tip("Trims the name on a word boundary; the date is never cut")
            } header: {
                Text("Name rules")
            } footer: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.sampleName)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.tertiary)
                        Text(normalizedName(for: Self.sampleName, rules: rules))
                    }
                }
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
            }
    }


    @ViewBuilder
    private var datesPanel: some View {
            Section {
                Toggle("Use the folder name", isOn: $useFolderNames)
                    .tip("Take the date, and a name for scan001, from the folder")
                Toggle("Use the PDF's creation date", isOn: $useMetadataDate)
                    .tip("When the PDF was written, often long after the period it covers")
                Toggle("Use the file's modification date", isOn: $useFileDate)
                    .tip("Least trustworthy: often just when the file landed here")
            } header: {
                Text("When the filename has no date")
            } footer: {
                Text("Tried in this order. A date already in the filename always wins, "
                     + "since it is the only one the document itself states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }


    @ViewBuilder
    private var originalsPanel: some View {
        if !moveOriginals {
            Section {
                Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                     text: "Applying will replace the originals. Nothing is kept and there is no undo.")
            }
        }

            Section {
                Toggle("Lock the output with a password", isOn: $encryptOutput)
                    .tip("Write every file out locked with your password")
                if encryptOutput {
                    LabeledContent("Password") {
                        SecureField("", text: $encryptPassword, prompt: Text("required"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Text("Encryption")
            } footer: {
                Text(encryptOutput && encryptPassword.isEmpty
                     ? "Without a password nothing is encrypted."
                     : "Kept in memory only, never written to preferences. Set it again next launch.")
                    .font(.caption)
                    .foregroundStyle(encryptOutput && encryptPassword.isEmpty
                                     ? Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
                                     : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep the originals", isOn: $moveOriginals)
                    .help("Off replaces each file in place, with no copy kept and no undo")
                if moveOriginals {
                    if backupCustomPath.isEmpty {
                        LabeledContent("Folder") {
                            TextField("", text: $backupFolderName, prompt: Text(defaultBackupFolderName))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                        }
                    } else {
                        LabeledContent("Folder") {
                            Text(backupCustomPath)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    HStack {
                        Button("Choose folder…") { choosingBackupFolder = true }
                            .buttonStyle(.link)
                            .tip("One folder for the originals of every source")
                        Spacer()
                        if !backupCustomPath.isEmpty {
                            Button("Use a folder per source") { backupCustomPath = "" }
                                .buttonStyle(.link)
                        }
                    }
                }
            } header: {
                Text("Originals")
            } footer: {
                Text(backupSummary)
                    .font(.caption)
                    .foregroundStyle(moveOriginals ? .secondary : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }


    @ViewBuilder
    private var aiPanel: some View {
            Section {
                LabeledContent("API key") {
                    if aiReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    } else {
                        Label("Not set", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    }
                }
                if availableModels.isEmpty {
                    LabeledContent("Model") {
                        TextField("", text: $aiModel, prompt: Text("gpt-4o-mini"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                } else {
                    Picker("Model", selection: $aiModel) {
                        // The stored one may not be in the list; keep it selectable.
                        if !availableModels.contains(aiModel) {
                            Text(aiModel).tag(aiModel)
                        }
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button(loadingModels ? "Loading…" : "Refresh models", action: loadModels)
                        .buttonStyle(.link)
                        .tip("Ask the endpoint what it can run")
                        .disabled(!aiReady || loadingModels)
                    if let modelsError {
                        Text(modelsError)
                            .font(.caption)
                            .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                            .lineLimit(2)
                    }
                }
                Toggle("Ask on each new file", isOn: $autoIdentify)
                    .disabled(!aiReady)
                    .help("One request per file as you reach it, billed like any other")
                SettingsLink {
                    Label("Open settings", systemImage: "gearshape")
                }
                .buttonStyle(.link)
                if aiReady && runner.pendingCount > 0 && runner.lastRunWasDry {
                    Button {
                        Task { await runner.identifyPending(client: aiClient, passwords: passwords, rules: rules) }
                    } label: {
                        Label("Name the \(runner.pendingCount) still pending", systemImage: "sparkles")
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("AI")
            } footer: {
                Text("Suggestions still go through the name rules above, and still have to "
                     + "be confirmed. Only the filename and the opening text are sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }


    @ViewBuilder
    private var runningPanel: some View {
            Section("Running") {
                Toggle("Watch the sources for changes", isOn: $watchSources)
                    .tip("Pick up new files on their own, keeping this review")
                    .onChange(of: watchSources) { _, _ in startWatching() }
                Picker("Default view", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Preview as soon as a source is added", isOn: $autoPreview)
                    .help("Preview is read-only, so this changes nothing on disk")
            }
    }


    @ViewBuilder
    private var bibtexPanel: some View {
            Section {
                Picker("Entry type", selection: $bibType) {
                    ForEach(BibType.allCases) { Text($0.label).tag($0) }
                }
                .help("Decides which fields count as missing. @misc asks only for a title.")
            } header: {
                Text("Entries")
            } footer: {
                Text("Publisher, journal and institution are never written: nothing here "
                     + "can read them off a PDF, so they are not reported as missing either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Line width") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { Double(bibLineWidth) },
                                              set: { bibLineWidth = Int($0) }),
                               in: 0...200, step: 10)
                        Text(bibLineWidth == 0 ? "off" : "\(bibLineWidth)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Picker("Indent", selection: $bibIndent) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("None").tag(0)
                }
                Picker("Values in", selection: $bibDelimiter) {
                    ForEach(BibStyle.Delimiter.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Align the equals signs", isOn: $bibAlign)
                Toggle("Trailing comma", isOn: $bibTrailingComma)
                Toggle("Blank line between entries", isOn: $bibBlankLines)
                Toggle("Sort fields alphabetically", isOn: $bibSortFields)
                Toggle("Lowercase ALL-CAPS values", isOn: $bibDropAllCaps)
                Toggle("Omit the file field", isOn: $bibOmitFile)
            } header: {
                Text("BibTeX")
            } footer: {
                Text("A long value wraps onto indented continuations. A single word "
                     + "longer than the budget is left whole, since breaking a path to "
                     + "satisfy a column is worse than exceeding it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }


    @ViewBuilder
    private var readingPanel: some View {
        Section {
            ForEach(palette.styles) { style in
                HStack(spacing: 8) {
                    ColorPicker("", selection: Binding(
                        get: { style.swatch },
                        set: { palette.setColour($0, on: style) }
                    ))
                    .labelsHidden()
                    .tip("Pick this highlighter's colour")

                    TextField("", text: Binding(
                        get: { style.meaning },
                        set: { palette.setMeaning($0, on: style) }
                    ), prompt: Text("What it means"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)

                    Button {
                        palette.remove(style)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(palette.styles.count < 2)
                    .tip(palette.styles.count < 2
                         ? "The last colour stays; without one there is no highlighter"
                         : "Remove this colour")
                }
            }

            HStack {
                Button { palette.add() } label: {
                    Label("Add a colour", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                .tip("Another highlighter, with its own meaning")
                Spacer()
                Button("Reset") { palette.resetToDefaults() }
                    .buttonStyle(.link)
                    .tip("Back to the five it started with")
            }
        } header: {
            Text("Highlighters")
        } footer: {
            Text("Shown beside the bar as you highlight and next to every mark, so the "
                 + "convention is legible where it is used rather than remembered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Mode") {
            Toggle("Reading mode", isOn: $chrome.reading)
                .tip("Hide the list, the header and the deciding controls", key: "⌘⇧R")
        }
    }

    @ViewBuilder
    private var logPanel: some View {
        Section {
            if runner.log.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            } else {
                // Newest first: the last thing that happened is what you came to check.
                ForEach(runner.log.reversed().prefix(200)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.kind.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(logColour(entry.kind))
                            Text(entry.at, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(entry.subject)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        } header: {
            Text("Activity")
        } footer: {
            HStack {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText(runner.log), forType: .string)
                }
                .buttonStyle(.link)
                .disabled(runner.log.isEmpty)
                Spacer()
                Button("Save…") { savingLog = true }
                    .buttonStyle(.link)
                    .disabled(runner.log.isEmpty)
            }
        }
    }

    private func logColour(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .failed: return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
        case .trashed: return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
        case .moved: return Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
        case .decrypted, .renamed, .applied: return Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
        case .skipped: return .secondary
        default: return Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
        }
    }

    @ViewBuilder
    private var appearancePanel: some View {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
    }


    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("API key, model and endpoint")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { chrome.reading.toggle() }
            } label: {
                Label("Reading", systemImage: chrome.reading ? "book.fill" : "book")
            }
            .tip("Hide everything but the page", key: "⌘⇧R")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            switch runner.phase {
            case .scanning:
                ProgressView().controlSize(.small)
            case .processing:
                ProgressView(value: Double(runner.done), total: Double(max(runner.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            case .idle:
                EmptyView()
            }

            Button(action: preview) {
                Label("Preview", systemImage: "eye")
            }
            .labelStyle(.titleAndIcon)
            .tip("Read-only: builds the plan, touches nothing", key: "⌘P")
            .disabled(selection.isEmpty || runner.busy)
            .keyboardShortcut("p", modifiers: .command)
            .help("Read-only. Builds the plan without touching a file.")

            Button(action: confirmApply) {
                Label(canApply ? "Apply to \(runner.actionable) files" : "Apply",
                      systemImage: "checkmark.circle")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
            .tip("Carry out the reviewed plan on disk", key: "⌘Return")
            .keyboardShortcut(.return, modifiers: .command)
            .help("Carry out the reviewed plan on disk")
        }
    }

    /// The selection is a set of non-overlapping roots: a folder absorbs anything already
    /// picked inside it, and nothing already covered is added twice.
    private func add(_ urls: [URL]) {
        let before = selection
        selection = mergedSources(selection, adding: urls)
        guard selection.map(\.path) != before.map(\.path) else { return }
        persistSources()
        startWatching()
        if autoPreview { preview() }
    }

    /// Removing a source takes its files with it, straight away.
    private func removeSource(_ url: URL) {
        selection.removeAll { $0 == url }
        persistSources()
        runner.removeSource(url, fingerprint: fingerprint)
        startWatching()
        expanded = []
        ensureSelectionAfterSourceChange()
    }

    private func ensureSelectionAfterSourceChange() {
        if selection.isEmpty {
            runner.reset()
            reviewing = nil
        } else if let current = reviewing, runner.item(current) == nil {
            reviewing = nil
        }
    }

    /// Watches whatever is selected, so files copied in while the app is open are picked
    /// up without being asked for.
    private func startWatching() {
        watcher?.stop()
        guard watchSources, !selection.isEmpty else {
            watcher = nil
            return
        }
        let created = FolderWatcher { Task { @MainActor in await absorbChanges() } }
        created.watch(selection)
        watcher = created
    }

    private func absorbChanges() async {
        guard watchSources, !selection.isEmpty else { return }
        await runner.absorbChanges(roots: selection, options: options(dryRun: true),
                                   fingerprint: fingerprint)
    }

    private func persistSources() {
        storedSources = selection.map(\.path).joined(separator: "\n")
    }

    /// Restores what was picked last time. Anything since moved or deleted is dropped
    /// rather than kept as a broken row.
    private func restoreSources() {
        guard selection.isEmpty else { return }
        let paths = storedSources.split(separator: "\n").map(String.init)
        selection = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if selection.map(\.path) != paths { persistSources() }
    }

    /// Everything the app remembers between launches.
    private func forgetEverything() {
        selection = []
        storedSources = ""
        expanded = []
        reviewing = nil
        runner.reset()
        covers.forget()
    }

    /// The results list is greedy, which makes `.defaultSize` lose and the window open at
    /// min-width by full-screen-height. Set the frame directly instead, and only when
    /// AppKit has no autosaved one, so a resize the user made still wins next launch.
    private func sizeWindowOnFirstLaunch() {
        guard !sizedWindow else { return }
        sizedWindow = true
        guard UserDefaults.standard.object(forKey: "NSWindow Frame main") == nil,
              let window = NSApp.windows.first else { return }
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
    }
}

// MARK: - Sidebar pieces

private struct SourceRow: View {
    let url: URL
    let remove: () -> Void

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .tip("Stop working on this source")
            .help("Remove this source")
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
    }
}

private struct Note: View {
    let icon: String
    let tint: Color
    let text: String
    var size: Font = .callout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
        }
        .font(size)
        .foregroundStyle(tint == .secondary ? .secondary : .primary)
    }
}

// MARK: - Results

private struct ResultsPane: View {
    @ObservedObject var runner: Runner
    @ObservedObject var covers: Covers
    @Binding var expanded: Set<String>
    @Binding var selected: String?
    let sourceCount: Int
    let previewIsCurrent: Bool
    let passwords: [String]
    let reading: Bool
    let watching: Bool
    @ObservedObject var palette: Palette
    let rules: NameRules
    let chooseFiles: () -> Void
    let preview: () -> Void
    let apply: () -> Void
    let applyOne: (Item, String) -> Void

    private var hasSources: Bool { sourceCount > 0 }


    @AppStorage("viewMode") private var mode: ViewMode = .catalogue
    @AppStorage("aiModel") private var aiModel = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var aiUseEnvironment = true
    @AppStorage("autoIdentify") private var autoIdentify = false
    @AppStorage("sortOrder") private var sortOrder: ItemSort = .folder
    @AppStorage("sortDescending") private var sortDescending = false
    /// Kept in step with the grid so the arrow keys can move by a row.
    @State private var gridColumns = 1
    @State private var showingShortcuts = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var confirmingBatchAI = false
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 460
    @AppStorage("notesShown") private var notesShown = false
    @StateObject private var annotator = Annotator()
    @State private var addingNote = false
    @State private var noteText = ""

    @AppStorage("bibOrder") private var bibOrder: BibOrder = .alphabetical
    @AppStorage("bibCompleteOnly") private var bibCompleteOnly = false
    @AppStorage("bibType") private var bibType: BibType = .book
    @State private var choosingMoveTarget = false
    @AppStorage("bibLineWidth") private var bibLineWidth = 80
    @AppStorage("bibIndent") private var bibIndent = 2
    @AppStorage("bibAlign") private var bibAlign = true
    @AppStorage("bibDelimiter") private var bibDelimiter: BibStyle.Delimiter = .braces
    @AppStorage("bibTrailingComma") private var bibTrailingComma = true
    @AppStorage("bibBlankLines") private var bibBlankLines = true
    @AppStorage("bibSortFields") private var bibSortFields = false
    @AppStorage("bibDropAllCaps") private var bibDropAllCaps = false
    @AppStorage("bibOmitFile") private var bibOmitFile = false

    private var bibStyle: BibStyle {
        BibStyle(lineWidth: bibLineWidth,
                 indent: String(repeating: " ", count: max(0, bibIndent)),
                 align: bibAlign,
                 delimiter: bibDelimiter,
                 trailingComma: bibTrailingComma,
                 blankLines: bibBlankLines,
                 sortFields: bibSortFields,
                 dropAllCaps: bibDropAllCaps,
                 omit: bibOmitFile ? ["file"] : [])
    }
    @AppStorage("bibShowsFile") private var bibShowsFile = false
    @State private var draft = ""
    /// The suggestion the draft started from, so an edit of yours can be told apart from
    /// a name you simply have not touched.
    @State private var suggestion = ""
    @FocusState private var editingName: Bool
    /// Held by the pane itself so the letter keys work the moment a preview lands, with
    /// no click needed to give something focus first.
    @FocusState private var paneFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var keyMonitor: Any?

    private var selectedItem: Item? {
        runner.results.first { $0.key == selected }
    }

    /// What the views show: everything, or only what the query matched.
    private var shown: [Item] {
        guard let keys = runner.matchingKeys else { return runner.results }
        return runner.results.filter { keys.contains($0.key) }
    }

    private var aiClient: AIClient {
        AIClient(baseURL: aiBaseURL, model: aiModel,
                 apiKey: resolvedKey(useEnvironment: aiUseEnvironment))
    }

    private var aiReady: Bool { !aiClient.apiKey.isEmpty }

    private func identifySelected() {
        guard let item = selectedItem, aiReady else { return }
        Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
    }

    private func currentName(_ item: Item) -> String {
        if case .confirmed(let name) = runner.decision(for: item) { return name }
        return item.destinationName
    }

    var body: some View {
        withDialogs(withKeys(core))
    }

    private var core: some View {
        Group {
            if runner.busy {
                busyState
            } else if runner.results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if !reading {
                        summaryBar
                        Divider()
                    }
                    split
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !reading {
                        Divider()
                        StatusStrip(runner: runner, watching: watching)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// The chain is split in two because one body carrying all of it is past what the
    /// type-checker will work through in reasonable time. Generic wrappers are checked
    /// independently, which is what makes it compile.
    private func withKeys<V: View>(_ view: V) -> some View {
        view
            .focusable()
            .focusEffectDisabled()
            .focused($paneFocused)
            .animation(.easeOut(duration: 0.18), value: runner.results.count)
            .onChange(of: runner.results.count) { _, _ in
            // Open the first level only, so a run lands looking like `ls` rather than
            // one closed folder or the whole tree at once.
            expanded.formUnion(runner.tree.filter { $0.children != nil }.map(\.id))
            ensureSelection()
        }
            .onChange(of: selected) { previous, new in
            // Folder rows carry no tag, so clicking one clears the selection. Put the
            // file back rather than letting the inspector swap out from under you.
            if new == nil, let previous, runner.results.contains(where: { $0.key == previous }) {
                selected = previous
                return
            }
            loadDraft()
        }
            .onAppear {
            ensureSelection()
            installKeyMonitor()
        }
        // A restyle rewrites the suggestions under the current selection.
            .onChange(of: runner.revision) { _, _ in refreshSuggestion() }
            .onChange(of: sortOrder) { _, order in
            sortDescending = order.descendsByDefault
            runner.sortResults(by: order, descending: sortDescending)
        }
            .onChange(of: sortDescending) { _, down in
            runner.sortResults(by: sortOrder, descending: down)
        }
            .onChange(of: runner.results.count) { _, count in
            guard count > 0, sortOrder != .folder else { return }
            runner.sortResults(by: sortOrder, descending: sortDescending)
        }
            .onDisappear(perform: removeKeyMonitor)
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
            .fileImporter(isPresented: $choosingMoveTarget,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { outcome in
            guard case .success(let urls) = outcome, let folder = urls.first,
                  let item = selectedItem else { return }
            runner.move(item, to: folder)
            advance()
        }
            .confirmationDialog("Ask AI for \(runner.pendingCount) names?",
                            isPresented: $confirmingBatchAI) {
            Button("Send \(runner.pendingCount) requests") {
                Task { await runner.identifyPending(client: aiClient, passwords: passwords, rules: rules) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One request per file, each carrying the filename and the first pages' text. "
                 + "You are billed by \(aiModel)'s provider.")
        }
            .alert("The service could not be reached", isPresented: aiErrorShown) {
            Button("OK") { runner.aiError = nil }
        } message: {
            Text(runner.aiError ?? "")
        }
    }

    /// Hoisted out of the modifier chain: an inline Binding there pushed the whole body
    /// past what the type-checker will work through.
    private var aiErrorShown: Binding<Bool> {
        Binding(get: { runner.aiError != nil }, set: { if !$0 { runner.aiError = nil } })
    }

    // MARK: Keys

    /// A List on macOS is an NSTableView, and its type-select eats plain letters to jump
    /// between rows, so `onKeyPress` on an ancestor never sees them. A local monitor runs
    /// ahead of the responder chain instead.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !runner.busy, !runner.results.isEmpty, selectedItem != nil else { return false }
        // Command combinations first: these are app-level and must work wherever focus is,
        // including while a name is being typed.
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "1": mode = .list; return true
            case "2": mode = .catalogue; return true
            case "3": mode = .bibliography; return true
            case "4": mode = .duplicates; return true
            case "r": revealInFinder(); return true
            case "d": runner.findDuplicates(passwords: passwords); return true
            case "\r" where event.modifierFlags.contains(.shift):
                runner.confirmAllPending()
                ensureSelection()
                return true
            default: return false
            }
        }
        guard event.modifierFlags.intersection([.option, .control]).isEmpty else { return false }

        // Anything being typed into, or any control that has its own idea of what a key
        // means, keeps the event. A table view does not: its type-select is what we are
        // deliberately replacing.
        if searchFocused { return false }
        if let responder = event.window?.firstResponder,
           responder is NSTextView || (responder is NSControl && !(responder is NSTableView)) {
            return false
        }

        // The lists are table views and move themselves; the catalogue is a grid and has
        // no such thing, so the arrows are handled here when a table is not in charge.
        let onATable = event.window?.firstResponder is NSTableView
        if !onATable {
            // In a grid a row is a row: up and down cross `gridColumns` items, while left
            // and right move to the neighbour.
            let row = mode == .catalogue ? max(1, gridColumns) : 1
            switch event.keyCode {
            case 125: step(by: row); return true    // down
            case 126: step(by: -row); return true   // up
            case 124: step(by: 1); return true      // right
            case 123: step(by: -1); return true     // left
            default: break
            }
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\r", "c": confirm()
        case "e": editingName = true
        case "s": skip()
        case "f": skipFolder()
        case "a": applyNow()
        case "g": identifySelected()
        case "m": choosingMoveTarget = true
        case "o": openInViewer()
        case "b": copyCitation()
        case "?": showingShortcuts = true
        case "/": searchFocused = true
        case "d": markDeleted()
        case "r": reopenSelected()
        case "j", "n": step(by: 1)
        case "k", "p": step(by: -1)
        default: return false
        }
        return true
    }

    /// Leaving the name field has to hand focus somewhere, or Return drops it on the
    /// floor: the row stops looking selected even though it still is.
    private func loadDraft() {
        if let item = selectedItem { runner.loadExcerpt(for: item, passwords: passwords) }
        editingName = false
        draft = selectedItem.map(currentName) ?? ""
        suggestion = selectedItem?.destinationName ?? ""
        if !runner.results.isEmpty { listFocused = true }
        askOnArrival()
    }

    /// With the toggle on, landing on a file that is still undecided and has never been
    /// looked at asks the model for a name. Guarded on all three, so browsing back over
    /// files already dealt with costs nothing.
    private func askOnArrival() {
        guard autoIdentify, aiReady, let item = selectedItem,
              runner.decision(for: item) == nil,
              runner.guesses[item.key] == nil,
              !runner.isThinking(item)
        else { return }
        Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
    }

    private func refreshSuggestion() {
        guard let item = selectedItem else { return }
        if draft == suggestion { draft = item.destinationName }
        suggestion = item.destinationName
    }

    private func reopenSelected() {
        guard let item = selectedItem else { return }
        runner.reopen(item)
        loadDraft()
    }

    /// Moves through the list without deciding anything.
    /// Moves by `offset`, clamped to the ends. A row jump near the last row should land
    /// on the last file rather than doing nothing.
    private func step(by offset: Int) {
        guard let current = runner.results.firstIndex(where: { $0.key == selected }),
              !runner.results.isEmpty else { return }
        let next = min(max(current + offset, 0), runner.results.count - 1)
        guard next != current else { return }
        selected = runner.results[next].key
    }

    private func confirm() {
        guard let item = selectedItem else { return }
        runner.confirm(item, as: draft)
        advance()
    }

    private func skip() {
        guard let item = selectedItem else { return }
        runner.skip(item)
        advance()
    }

    private func skipFolder() {
        guard let item = selectedItem else { return }
        runner.skipFolder(of: item)
        advance()
    }

    /// Carries out this one file straight away, then moves on like any other decision.
    private func applyNow() {
        guard let item = selectedItem, runner.decision(for: item) != .applied else { return }
        applyOne(item, draft)
        advance()
    }

    /// One menu, built for whichever file was right-clicked rather than the selected one,
    /// because a right-click on a row people have not selected still means that row.
    private func fileMenu(_ item: Item) -> FileContextMenu {
        FileContextMenu(
            item: item,
            confirm: {
                selected = item.key
                runner.confirm(item, as: item.destinationName)
                advance()
            },
            identify: {
                selected = item.key
                Task { await runner.identify(item, client: aiClient, passwords: passwords, rules: rules) }
            },
            moveTo: {
                selected = item.key
                choosingMoveTarget = true
            },
            trash: { runner.markForDeletion(item) },
            skip: { runner.skip(item) }
        )
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealInFinder() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.currentURL])
    }

    private func openInViewer() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.open(item.currentURL)
    }

    /// Copies this file's BibTeX entry. When the entry is short of what its type wants and
    /// a key is configured, the model is asked first, so one action produces a citation
    /// worth pasting rather than a stub.
    private func copyCitation() {
        guard let item = selectedItem else { return }
        Task {
            runner.ensureBib()
            if let entry = runner.bibByItem[item.key], !entry.isComplete,
               aiReady, runner.guesses[item.key] == nil {
                await runner.identify(item, client: aiClient, passwords: passwords, rules: rules)
                runner.ensureBib()
            }
            guard let entry = runner.bibByItem[item.key] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bibtexBlock(entry, style: bibStyle) + "\n", forType: .string)
            runner.note(.edited, subject: item.relativePath, detail: "citation copied")
        }
    }

    private func markDeleted() {
        guard let item = selectedItem else { return }
        runner.markForDeletion(item)
        advance()
    }

    /// After a decision, jump to the next file still waiting. When none are left the
    /// selection stays put so the last thing decided is still on screen.
    private func advance() {
        if let next = runner.nextPending() { selected = next.key }
        loadDraft()
    }

    @ViewBuilder
    private var browser: some View {
        switch mode {
        case .catalogue: catalogue
        case .list: list
        case .bibliography: bibliography
        case .duplicates: duplicatesView
        }
    }

    /// The same tree, showing what each file will contribute to the .bib. Selection is
    /// shared with the other two views, so the preview on the right keeps up and an
    /// entry can be checked against the page it came from.
    private var bibliography: some View {
        VStack(spacing: 0) {
            bibBar
            Divider()
            if bibShowsFile {
                BibFileView(entries: runner.bib, order: $bibOrder, completeOnly: $bibCompleteOnly,
                            style: bibStyle)
            } else {
                bibEntryList
            }
        }
        .onAppear {
            runner.bibType = bibType
            runner.ensureBib()
        }
        .onChange(of: runner.revision) { _, _ in runner.ensureBib() }
        .onChange(of: bibType) { _, new in
            runner.bibType = new
            runner.ensureBib()
        }
    }

    private var bibEntryList: some View {
        Group {
            ScrollViewReader { scroll in
                List(selection: $selected) {
                    ForEach(runner.tree) { node in
                        BibNodeView(node: node, expanded: $expanded, runner: runner)
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .onChange(of: selected) { _, new in
                    guard let new else { return }
                    expanded.formUnion(runner.ancestors(of: new))
                    withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    /// Duplicates get their own view rather than a badge, because deciding between two
    /// copies means seeing them next to each other and next to the page.
    private var duplicatesView: some View {
        Group {
            if runner.findingDuplicates {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Comparing \(runner.results.count) files").font(.headline)
                    Text("Hashing what shares a size, then reading opening pages")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runner.duplicates.isEmpty {
                ContentUnavailableView {
                    Label(runner.duplicatesChecked ? "No duplicates" : "Not compared yet",
                          systemImage: runner.duplicatesChecked ? "checkmark.seal" : "doc.on.doc")
                } description: {
                    Text(runner.duplicatesChecked
                         ? "Every file here is its own book."
                         : "Compare the \(runner.results.count) files by content and by name.")
                } actions: {
                    if !runner.duplicatesChecked {
                        Button("Find duplicates") { runner.findDuplicates(passwords: passwords) }
                .tip("Compare by bytes, by opening pages, and by name", key: "⌘D")
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    duplicatesBar
                    Divider()
                    List(selection: $selected) {
                        ForEach(runner.duplicates) { group in
                            DuplicateSection(group: group, runner: runner)
                        }
                    }
                    .listStyle(.inset)
                    .focused($listFocused)
                }
            }
        }
    }

    private var duplicatesBar: some View {
        let identical = runner.duplicates.filter { $0.kind == .identical }.count
        let sameText = runner.duplicates.filter { $0.kind == .sameText }.count
        let reclaimable = runner.duplicates.reduce(0) { $0 + $1.reclaimable }
        return HStack(spacing: 10) {
            Text("\(identical) identical, \(sameText) same pages, "
                 + "\(runner.duplicates.count - identical - sameText) by name")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(reclaimable), countStyle: .file)
                 + " in spare copies")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Recheck") { runner.findDuplicates(passwords: passwords) }
                .controlSize(.small)
                .tip("Compare again, after changes", key: "⌘D")
            Button("Trash \(runner.identicalExtras) identical spares") {
                runner.markIdenticalExtras()
                ensureSelection()
            }
            .controlSize(.small)
            .tip("Byte-identical groups only; name matches are left alone")
            .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
            .disabled(runner.identicalExtras == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var bibDocument: String {
        bibtexDocument(runner.bib, includeIncomplete: !bibCompleteOnly, order: bibOrder)
    }

    private var bibBar: some View {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
            let incomplete = runner.bib.filter { !$0.isComplete }.count
            Text("\(runner.bib.count) entries").font(.callout).foregroundStyle(.secondary)
            if incomplete > 0 {
                Label("\(incomplete) incomplete", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    .help("Ask AI on those files to fill in author and year")
            }
            Spacer()
            Picker("", selection: $bibShowsFile) {
                Text("Entries").tag(false)
                Text("File").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tip("Browse the entries, or read the generated file")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
      .fixedSize(horizontal: false, vertical: true)
      .background(.bar)
    }

    /// A shelf of covers. `LazyVGrid` only builds what is on screen, and the cover store
    /// only renders what is built, so the cost follows the window and not the collection.
    ///
    /// The column count is computed here rather than left to `.adaptive`, because the
    /// arrow keys need to know it: in a grid, up and down mean a row, not a neighbour.
    private var catalogue: some View {
        GeometryReader { geometry in
            let count = catalogueColumns(for: geometry.size.width)
            catalogueGrid(columns: count)
                .onAppear { gridColumns = count }
                .onChange(of: count) { _, new in gridColumns = new }
        }
    }

    private func catalogueColumns(for width: CGFloat) -> Int {
        let spacing: CGFloat = 18
        let ideal: CGFloat = 168
        return max(1, Int((width - spacing + spacing) / (ideal + spacing)))
    }

    private func catalogueGrid(columns: Int) -> some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: 18), count: columns)
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: layout, alignment: .leading, spacing: 18) {
                    ForEach(runner.results) { item in
                        CoverCard(
                            item: item,
                            decision: runner.decision(for: item),
                            duplicate: runner.duplicateKind[item.key],
                            passwords: passwords,
                            covers: covers,
                            isSelected: selected == item.key
                        )
                        .id(item.key)
                        .onTapGesture { selected = item.key }
                    }
                }
                .padding(18)
            }
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Two panes with a divider the user owns. `HSplitView` renegotiates its own widths
    /// whenever its children change, which is why the inspector kept jumping; here the
    /// width only ever changes because someone dragged it, and it is remembered.
    /// Two panes with a divider the user owns. `HSplitView` renegotiates its own widths
    /// whenever its children change, which is why the inspector kept jumping; here the
    /// width only ever changes because someone dragged it, and it is remembered.
    private var split: some View {
        GeometryReader { geometry in
            let maximum = max(360, geometry.size.width - 360)
            let width = min(max(inspectorWidth, 360), maximum)
            HStack(spacing: 0) {
                // Reading gives the whole window to the page.
                if !reading {
                    browser.frame(maxWidth: .infinity, maxHeight: .infinity)
                    divider(width: width, maximum: maximum)
                }
                inspector
                    .frame(width: reading ? nil : width)
                    .frame(maxWidth: reading ? .infinity : nil, maxHeight: .infinity)
                if notesShown {
                    Divider()
                    NotesRail(annotator: annotator, palette: palette,
                              addingNote: $addingNote, noteText: $noteText,
                              lastColour: (palette.styles.first ?? Palette.defaults[0]).nsColor,
                              title: selectedItem?.destinationName ?? "Notes",
                              source: selectedItem?.currentURL.path ?? "",
                              close: { withAnimation(.easeOut(duration: 0.15)) { notesShown = false } })
                        .frame(width: 240)
                }
            }
        }
    }

    private func divider(width: CGFloat, maximum: CGFloat) -> some View {
        Divider()
            .background(.separator)
            .frame(width: 1)
            .overlay {
                // A 10pt grab strip: a 1pt divider is not a target anyone can hit.
                Rectangle()
                    .fill(.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                inspectorWidth = min(max(width - value.translation.width, 360), maximum)
                            }
                    )
            }
    }

    private var list: some View {
        ScrollViewReader { scroll in
            List(selection: $selected) {
                ForEach(runner.tree) { node in
                    NodeView(node: node, expanded: $expanded, runner: runner,
                             menu: fileMenu, visible: runner.matchingKeys)
                }
            }
            .listStyle(.inset)
            // An NSTableView draws its selection grey unless it is the first responder,
            // which is why the highlight looked inert while the keys were driving it.
            .focused($listFocused)
            .onChange(of: selected) { _, new in
                guard let new else { return }
                expanded.formUnion(runner.ancestors(of: new))
                withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(new, anchor: .center) }
            }
        }
    }

    // MARK: Review inspector

    @ViewBuilder
    private var inspector: some View {
        if let item = selectedItem {
            ReviewInspector(
                item: item,
                runner: runner,
                passwords: passwords,
                draft: $draft,
                editing: $editingName,
                confirm: confirm,
                skip: skip,
                skipFolder: skipFolder,
                applyNow: applyNow,
                identify: identifySelected,
                copyCitation: copyCitation,
                autoIdentify: $autoIdentify,
                reveal: revealInFinder,
                openExternally: openInViewer,
                moveTo: { choosingMoveTarget = true },
                aiReady: aiReady,
                markDeleted: markDeleted,
                reopen: reopenSelected,
                reset: { draft = item.destinationName },
                leaveField: { editingName = false; listFocused = true },
                excerpt: runner.excerpt(for: item),
                reading: reading,
                annotator: annotator,
                palette: palette
            )
        } else if runner.lastRunWasDry && !runner.results.isEmpty && runner.pendingCount == 0 {
            ContentUnavailableView(
                "Every file reviewed",
                systemImage: "checkmark.seal",
                description: Text("Apply is unlocked. Pick a row to look at it again.")
            )
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "sidebar.right",
                description: Text("Pick a file to see it.")
            )
        }
    }

    /// Fills in a selection only when there is not already a good one. Whatever file you
    /// are on stays put: it is only moved by a decision, by the arrow and J/K keys, or by
    /// a new run that no longer contains it.
    private func ensureSelection() {
        if let selected, runner.results.contains(where: { $0.key == selected }) {
            loadDraft()
            return
        }
        selected = runner.nextPending()?.key
        loadDraft()
    }

    // MARK: Header

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
              HStack(spacing: 10) {
                searchField
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tip("Which view of the same files", key: "⌘1 to ⌘4")

                ForEach(runner.statusCounts, id: \.0) { status, count in
                    StatusPill(status: status, count: count)
                }
                Spacer(minLength: 8)
                stateLabel
                    .lineLimit(1)
                    .fixedSize()
              }
              .padding(.trailing, 2)
            }
            .scrollIndicators(.hidden)

            if runner.lastRunWasDry {
              ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ProgressView(value: Double(runner.reviewed),
                                 total: Double(max(runner.results.count, 1)))
                        .frame(width: 140)
                    if let keys = runner.matchingKeys {
                        Text("\(keys.count) of \(runner.results.count) shown")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(keys.isEmpty
                                             ? Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
                                             : .secondary)
                    } else if runner.pendingCount == 0 {
                        Label("All \(runner.results.count) reviewed", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    } else {
                        Text("\(runner.reviewed) of \(runner.results.count) reviewed")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ItemSort.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 150)
                    .help("Reorders within each folder, and across the catalogue")
                    Button {
                        sortDescending.toggle()
                    } label: {
                        Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                    }
                    .controlSize(.small)
                    .tip(sortDescending ? "Largest or newest first" : "Smallest or oldest first")
                    .help(sortDescending ? "Largest or newest first" : "Smallest or oldest first")

                    duplicateControls
                    if aiReady && runner.pendingCount > 0 {
                        Button("Ask AI for \(runner.pendingCount)") { confirmingBatchAI = true }
                            .controlSize(.small)
                            .tip("One billed request per file still waiting")
                    }
                    Menu {
                        Button("Catalogue as Markdown") {
                            copyText(markdownCatalogue(runner.results, known: runner.guesses))
                        }
                        Button("Bibliography as Markdown") {
                            runner.ensureBib()
                            copyText(markdownBibliography(runner.bib))
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                    .tip("Copy the list or the bibliography as Markdown")

                    Button("Confirm all remaining") {
                        runner.confirmAllPending()
                        ensureSelection()
                    }
                    .controlSize(.small)
                    .tip("Accept every suggestion still waiting", key: "⌘⇧Return")
                    .disabled(runner.pendingCount == 0)
                }
                .padding(.trailing, 2)
              }
              .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // A bar keeps its natural height. Without this it absorbs whatever room the panes
        // below leave, and everything inside it stretches to match.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { runner.search(query, passwords: passwords) }
                .onChange(of: query) { _, new in
                    // Metadata is instant; a text query waits for Return so a shelf is
                    // not read from end to end on every keystroke.
                    if new.isEmpty || !Query(new).needsText {
                        runner.search(new, passwords: passwords)
                    }
                }
            if runner.searching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button {
                    query = ""
                    runner.search("", passwords: passwords)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .tip("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 240)
        .tip("Search names, or use folder: size> text: …", key: "/")
    }

    @ViewBuilder
    private var duplicateControls: some View {
        if runner.findingDuplicates {
            ProgressView().controlSize(.small)
            Text("Comparing…").font(.callout).foregroundStyle(.secondary)
        } else if runner.duplicates.isEmpty {
            Button("Find duplicates") { runner.findDuplicates() }
                .controlSize(.small)
        } else {
            let identical = runner.duplicates.filter { $0.kind == .identical }.count
            let sameText = runner.duplicates.filter { $0.kind == .sameText }.count
            let likely = runner.duplicates.count - identical - sameText
            Text("\(identical) identical, \(sameText) same pages, \(likely) by name")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Trash \(runner.identicalExtras) spare copies") {
                runner.markIdenticalExtras()
                ensureSelection()
            }
            .controlSize(.small)
            .disabled(runner.identicalExtras == 0)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        if !runner.lastRunWasDry {
            Label("Applied, files on disk have changed", systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        } else if !previewIsCurrent {
            Label("Settings changed, preview again", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
        } else if runner.showingCached {
            Label("From last time, rechecking the disk", systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if runner.appliedCount > 0 {
            Label("\(runner.appliedCount) applied so far, the rest is still a preview",
                  systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        } else {
            Label("Preview only, nothing has changed on disk", systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var busyState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text(runner.phase == .scanning ? "Looking for PDFs" : "Processing files")
                .font(.headline)
            Text(runner.phase == .scanning
                 ? "\(runner.found) found so far"
                 : "\(runner.done) of \(runner.total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(runner.current)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 480)
                .opacity(runner.current.isEmpty ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(hasSources ? "Ready to run" : "Nothing selected yet",
                  systemImage: hasSources ? "wand.and.sparkles" : "tray.and.arrow.down")
        } description: {
            Text(hasSources
                 ? "\(sourceCount) source\(sourceCount == 1 ? "" : "s") queued. Preview first, then apply."
                 : "Drop folders or PDFs anywhere in this window.")
        } actions: {
            if hasSources {
                Button("Preview", action: preview).buttonStyle(.borderedProminent)
            } else {
                Button("Choose Files or Folders…", action: chooseFiles)
                    .buttonStyle(.borderedProminent)
            }
        }
        // The whole empty pane is the target, not just the button.
        .contentShape(Rectangle())
        .onTapGesture { if !hasSources { chooseFiles() } }
    }
}

// MARK: - Review inspector

private struct ReviewInspector: View {
    let item: Item
    @ObservedObject var runner: Runner
    let passwords: [String]
    @Binding var draft: String
    @FocusState.Binding var editing: Bool
    let confirm: () -> Void
    let skip: () -> Void
    let skipFolder: () -> Void
    let applyNow: () -> Void
    let identify: () -> Void
    let copyCitation: () -> Void
    @Binding var autoIdentify: Bool
    let reveal: () -> Void
    let openExternally: () -> Void
    let moveTo: () -> Void
    let aiReady: Bool
    let markDeleted: () -> Void
    let reopen: () -> Void
    let reset: () -> Void
    let leaveField: () -> Void
    let excerpt: String?
    let reading: Bool

    @ObservedObject var annotator: Annotator
    @ObservedObject var palette: Palette
    @AppStorage("inspectorPanel") private var panel: InspectorPanel = .rename
    @AppStorage("inspectorCollapsed") private var collapsed = false
    @AppStorage("notesShown") private var notesShown = false
    @AppStorage("contentsShown") private var contentsShown = false
    @State private var addingNote = false
    @State private var noteText = ""
    @AppStorage("lastHighlightColour") private var lastColourID = ""
    @State private var hovered: UUID?
    @State private var hoveringNote = false

    private var lastStyle: HighlightStyle? {
        palette.styles.first { $0.id.uuidString == lastColourID } ?? palette.styles.first
    }

    private var hoveredMeaning: String? {
        guard let hovered, let style = palette.styles.first(where: { $0.id == hovered })
        else { return nil }
        return style.meaning.isEmpty ? "Unnamed highlighter" : style.meaning
    }

    /// While reading, the deciding controls stay out of the way.
    private var showBottom: Bool { !collapsed && !reading }

    private var decision: Decision? { runner.decision(for: item) }
    private var isEdited: Bool { sanitizedFilename(draft) != item.destinationName }

    private var pendingInFolder: Int { runner.pendingInFolder(of: item) }

    private var folderName: String {
        let folder = (item.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "this folder" : (folder as NSString).lastPathComponent
    }

    private var folderScopeLabel: String {
        pendingInFolder > 0 ? "Skip folder (\(pendingInFolder))" : "Skip folder"
    }

    /// Just the folder. The filename is already on screen twice, in the field and in the
    /// "was" line under it.
    private var folderPath: String {
        let folder = (item.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "in the selected folder" : folder + "/"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    if contentsShown && !annotator.contents.isEmpty {
                        ContentsRail(annotator: annotator,
                                     close: { withAnimation(.easeOut(duration: 0.15)) {
                                         contentsShown = false } })
                            .frame(width: 196)
                        Divider()
                    }
                    PDFPreview(url: item.currentURL, passwords: passwords, annotator: annotator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.35))
                    .overlay(alignment: .topTrailing) { lockedOverlay }
                    .overlay(alignment: .topLeading) { floatingSelectionBar }
                }

                Divider()
                panelHeader

                if showBottom {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if panel == .rename { renamePanel }
                            else { MetadataPanel(item: item, excerpt: excerpt) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
        }
        .onAppear { if draft.isEmpty { draft = item.destinationName } }
        .onChange(of: item.key) { _, _ in
            editing = false
            addingNote = false
            noteText = ""
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            StatusPill(status: item.status, count: nil)

            if !reading {
                Picker("", selection: $panel) {
                    ForEach(InspectorPanel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(collapsed)
                .tip("Rename this file, or read what it says about itself")
            }

            Spacer(minLength: 8)

            if !annotator.contents.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { contentsShown.toggle() }
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(contentsShown ? Color.accentColor : .secondary)
                .tip(contentsShown ? "Hide the contents" : "Table of contents", key: "⌘⇧T")
            }

            Button(action: reveal) { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .tip("Reveal in Finder", key: "⌘R")
            Button(action: openExternally) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .tip("Open in the default PDF viewer", key: "O")

            Button {
                withAnimation(.easeOut(duration: 0.15)) { notesShown.toggle() }
            } label: {
                if reading {
                    Label(notesShown ? "Hide notes" : "Notes",
                          systemImage: notesShown ? "sidebar.trailing" : "note.text")
                } else {
                    Image(systemName: notesShown ? "sidebar.trailing" : "note.text")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(notesShown ? Color.accentColor : .secondary)
            .help(notesShown ? "Hide the notes (⌘⇧N)" : "Show notes and highlights (⌘⇧N)")
            .overlay(alignment: .topTrailing) {
                if !annotator.marks.isEmpty && !notesShown {
                    Circle()
                        .fill(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                }
            }

            if !reading {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(collapsed ? "Show the panel" : "Hide the panel, give the room to the page")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    /// The marking bar, placed against the selection rather than parked at an edge.
    ///
    /// It sits above the selected lines where there is room and below them otherwise, and
    /// is kept inside the pane so it cannot end up half off the side.
    @ViewBuilder
    private var floatingSelectionBar: some View {
        if annotator.hasSelection {
            GeometryReader { geometry in
                let bar = CGSize(width: 250, height: 40)
                let box = annotator.selectionRect ?? CGRect(
                    x: geometry.size.width / 2, y: geometry.size.height - 60, width: 0, height: 0)
                let above = box.minY - bar.height - 8
                let y = above > 8 ? above : min(box.maxY + 8, geometry.size.height - bar.height - 8)
                let x = min(max(box.midX - bar.width / 2, 8), max(8, geometry.size.width - bar.width - 8))

                selectionBar
                    .frame(width: bar.width, height: bar.height)
                    .offset(x: x, y: y)
                    .animation(.easeOut(duration: 0.12), value: box)
            }
            .transition(.opacity)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 7) {
            ForEach(palette.styles) { style in
                Button {
                    annotator.highlightSelection(colour: style.nsColor)
                    lastColourID = style.id.uuidString
                    notesShown = true
                } label: {
                    Circle()
                        .fill(style.swatch)
                        .frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(.primary.opacity(
                            style.id == (hovered ?? lastStyle?.id) ? 0.6 : 0.15), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                // Named in the bar itself rather than left to the system tooltip, which
                // waits a second or two: too slow for a palette whose whole point is
                // knowing what a colour stands for.
                .onHover { hovered = $0 ? style.id : nil }
            }

            Divider().frame(height: 16)

            Button {
                notesShown = true
                addingNote = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.plain)
            .onHover { hoveringNote = $0 }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .top) { meaningLabel }
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }

    /// What the colour under the pointer means, shown immediately above the bar.
    @ViewBuilder
    private var meaningLabel: some View {
        if let text = hoveredMeaning ?? (hoveringNote ? "Highlight and attach a note" : nil) {
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .offset(y: -24)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var renamePanel: some View {
        Text(folderPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)

        VStack(alignment: .leading, spacing: 4) {
            Text("New name").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($editing)
                .onSubmit(confirm)
                .onKeyPress(.escape) {
                    leaveField()
                    return .handled
                }
                .strikethrough(decision == .deleted)
            HStack(spacing: 6) {
                Text("was \(item.sourceName)")
                if isEdited {
                    Text("edited")
                        .foregroundStyle(Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255)))
                    Button("Reset", action: reset).buttonStyle(.link)
                }
                Spacer(minLength: 0)
                decisionBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        if !item.message.isEmpty {
            Text(item.message)
                .font(.caption)
                .foregroundStyle(item.status == .failed ? .red : .orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        actionRows

        Text(decision == .deleted
             ? "Moves to the Trash on apply, so it stays recoverable. R puts it back."
             : "J or N next, K or P previous. ? lists every shortcut.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var actionRows: some View {
        VStack(spacing: 7) {
          ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Button(action: confirm) { KeyLabel("\u{21A9}", "Confirm") }
                    .buttonStyle(.borderedProminent)
                Button(action: { editing = true }) { KeyLabel("E", "Edit name") }
                Button(action: copyCitation) { KeyLabel("B", "Citation") }
                    .tip("Copy its BibTeX entry, asking the model if fields are missing", key: "B")
                Toggle(isOn: $autoIdentify) {
                    Image(systemName: autoIdentify ? "sparkles.rectangle.stack.fill"
                                                   : "sparkles.rectangle.stack")
                }
                .toggleStyle(.button)
                .disabled(!aiReady)
                .tip(autoIdentify ? "Asking the model on each new file"
                                  : "Ask the model on each new file")
                Button(action: identify) { KeyLabel("G", "Ask AI") }
                    .disabled(!aiReady || runner.isThinking(item))
                    .tip(aiReady ? "Read the opening pages and suggest a title"
                             : "Add an API key in Settings first", key: "G")
                Spacer(minLength: 0)
            }
          }
          .scrollIndicators(.hidden)

          ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Button(action: skip) { KeyLabel("S", "Skip") }
                    .tip("Leave this file exactly as it is", key: "S")
                Button(action: skipFolder) { KeyLabel("F", folderScopeLabel) }
                    .disabled(pendingInFolder == 0)
                    .tip("Skip the rest of \(folderName)", key: "F")
                if decision != nil {
                    Button(action: reopen) { KeyLabel("R", "Reopen") }
                }
                Spacer(minLength: 0)
                Button(action: applyNow) { KeyLabel("A", "Apply now") }
                    .disabled(decision == .applied)
                    .tint(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    .tip("Rename this one file on disk now", key: "A")
                Button(action: moveTo) { KeyLabel("M", "Move to…") }
                    .tint(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
                Button(action: markDeleted) { KeyLabel("D", "Trash") }
                    .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                    .tip("To the Trash on apply, recoverable", key: "D")
            }
          }
          .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var lockedOverlay: some View {
        if item.status == .locked {
            Label("No password matched, cannot be shown", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
        }
    }

    @ViewBuilder
    private var decisionBadge: some View {
        switch decision {
        case .confirmed:
            Label("Confirmed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .applied:
            Label("Applied", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .skipped:
            Label("Skipped", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        case .deleted:
            Label("Will be trashed", systemImage: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
        case .moveTo(let folder):
            Label("Moving to \(folder.lastPathComponent)", systemImage: "arrow.right.circle.fill")
                .foregroundStyle(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
        case nil:
            Label("Not reviewed", systemImage: "circle.dotted")
                .foregroundStyle(.tertiary)
        }
    }
}

/// A button label that carries its own shortcut, so the keys are discoverable without a
/// legend somewhere else in the window.
private struct KeyLabel: View {
    let key: String
    let title: String

    init(_ key: String, _ title: String) {
        self.key = key
        self.title = title
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption2.weight(.bold).monospaced())
                .frame(width: 14, height: 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(title)
        }
    }
}

/// A `PDFView` that fits the page to the pane's width and starts at the top of the
/// document, rather than shrinking the whole page to fit and centring it.
private final class FitWidthPDFView: PDFView {
    private var wantsTopScroll = false

    override func layout() {
        super.layout()
        fitToWidth()
    }

    func showFromTop() {
        wantsTopScroll = true
        needsLayout = true
    }

    /// PDFView keeps its own scroll view, whose content width already excludes a legacy
    /// scroller. Measuring that instead of `bounds` stops the fit from oscillating by a
    /// scroller's width on every layout pass.
    private var availableWidth: CGFloat {
        let inner = subviews.compactMap { $0 as? NSScrollView }.first
        return inner.map { $0.contentSize.width } ?? bounds.width
    }

    private func fitToWidth() {
        guard let page = document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: displayBox).width
        let width = availableWidth
        guard pageWidth > 0, width > 0 else { return }

        let target = min(max(width / pageWidth, minScaleFactor), maxScaleFactor)
        if abs(scaleFactor - target) > 0.002 { scaleFactor = target }

        if wantsTopScroll {
            wantsTopScroll = false
            let top = CGPoint(x: 0, y: page.bounds(for: displayBox).maxY)
            go(to: PDFDestination(page: page, at: top))
        }
    }
}

/// Renders the PDF as it is right now, unlocking it for display with the same passwords
/// the run would use. Read-only: the file on disk is untouched.
private struct PDFPreview: NSViewRepresentable {
    let url: URL
    let passwords: [String]
    var annotator: Annotator?

    func makeCoordinator() -> Coordinator { Coordinator(annotator: annotator) }

    func makeNSView(context: Context) -> FitWidthPDFView {
        let view = FitWidthPDFView()
        // autoScales fits the whole page and centres it, which is the opposite of what a
        // page of text wants.
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged),
            name: .PDFViewSelectionChanged, object: view
        )
        return view
    }

    func updateNSView(_ view: FitWidthPDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        let document = PDFDocument(url: url)
        if document?.isLocked == true {
            for password in passwords {
                if document?.unlock(withPassword: password) == true { break }
            }
        }
        view.document = document
        view.showFromTop()
        if let annotator {
            Task { @MainActor in annotator.attach(view, url: url) }
        }
    }

    final class Coordinator: NSObject {
        let annotator: Annotator?
        init(annotator: Annotator?) { self.annotator = annotator }

        @objc func selectionChanged() {
            Task { @MainActor in annotator?.selectionChanged() }
        }
    }
}

private struct NodeView: View {
    let node: Node
    @Binding var expanded: Set<String>
    @ObservedObject var runner: Runner
    var menu: (Item) -> FileContextMenu = { item in
        FileContextMenu(item: item, confirm: {}, identify: {}, moveTo: {}, trash: {}, skip: {})
    }
    /// Nil means no filter. A folder with nothing visible under it disappears too.
    var visible: Set<String>?

    private var isHidden: Bool {
        guard let visible else { return false }
        if let key = node.itemKey { return !visible.contains(key) }
        return !anyVisible(node, visible)
    }

    private func anyVisible(_ node: Node, _ visible: Set<String>) -> Bool {
        if let key = node.itemKey { return visible.contains(key) }
        return (node.children ?? []).contains { anyVisible($0, visible) }
    }

    var body: some View {
        if isHidden {
            EmptyView()
        } else if let key = node.itemKey, let item = runner.item(key) {
            ResultRow(item: item, decision: runner.decision(for: item),
                      duplicate: runner.duplicateKind[item.key])
                .tag(key)
                .id(key)
                .contextMenu { menu(item) }
                // A real file drag: Finder and anything else that takes one gets a copy.
                .onDrag { NSItemProvider(contentsOf: item.currentURL) ?? NSItemProvider() }
        } else {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    NodeView(node: child, expanded: $expanded, runner: runner,
                             menu: menu, visible: visible)
                }
            } label: {
                Label {
                    Text(node.name).fontWeight(.medium)
                    Text("\(count(node))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                }
                // The whole row opens the folder, not just the chevron.
                .contentShape(Rectangle())
                .onTapGesture { expansion.wrappedValue.toggle() }
            }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { open in
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
    }

    private func count(_ node: Node) -> Int {
        guard let children = node.children else { return 1 }
        return children.reduce(0) { $0 + count($1) }
    }
}

private struct ResultRow: View {
    let item: Item
    let decision: Decision?
    var duplicate: DuplicateGroup.Kind?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            reviewMark
                .frame(width: 15)
                .padding(.top, 2)
            StatusPill(status: item.status, count: nil)
                .frame(width: 108, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(decision == .deleted ? item.sourceName : shownName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(decision == .deleted)
                stats
                if decision == .deleted {
                    Label("will be moved to the Trash", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                } else if shownName != item.sourceName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(item.sourceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("already normalized")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !item.message.isEmpty {
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(item.status == .failed ? .red : .orange)
                }
            }
            Spacer(minLength: 0)
            if let duplicate {
                Image(systemName: duplicateIcon(duplicate))
                    .foregroundStyle(duplicateColour(duplicate))
                    .help(duplicateExplanation(duplicate))
            }
        }
        .padding(.vertical, 3)
        .opacity(decision == .skipped ? 0.45 : 1)
    }

    private var shownName: String {
        if case .confirmed(let name) = decision { return name }
        return item.destinationName
    }

    /// Size, length and age, which is what tells two similar-looking files apart.
    @ViewBuilder
    private var stats: some View {
        let parts = [
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            item.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" },
            item.modifiedDate.map { $0.formatted(date: .abbreviated, time: .omitted) },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var reviewMark: some View {
        markGlyph.tip(decision?.explanation ?? undecidedExplanation)
    }

    @ViewBuilder
    private var markGlyph: some View {
        switch decision {
        case .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .applied:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
        case .deleted:
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
        case .moveTo:
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
        case nil:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}

/// One book on the shelf: cover, name, and the two badges that matter (what you decided,
/// and whether another copy of it exists).
private struct CoverCard: View {
    let item: Item
    let decision: Decision?
    let duplicate: DuplicateGroup.Kind?
    let passwords: [String]
    @ObservedObject var covers: Covers
    let isSelected: Bool

    private var name: String {
        if case .confirmed(let confirmed) = decision { return confirmed }
        return item.destinationName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary.opacity(0.5))
                // Touching `revision` is what redraws this card when its render lands.
                let _ = covers.revision
                if let cover = covers.cover(for: item, passwords: passwords, height: 320) {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                } else {
                    Image(systemName: item.status == .locked ? "lock.fill" : "book.closed")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 168)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { badges }

            Text(name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .foregroundStyle(decision == .deleted ? .secondary : .primary)
                .strikethrough(decision == .deleted)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .opacity(decision == .skipped ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 3) {
            if let duplicate {
                Image(systemName: duplicateIcon(duplicate))
                    .foregroundStyle(duplicateColour(duplicate))
                    .help(duplicateExplanation(duplicate))
            }
            switch decision {
            case .confirmed: Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
            case .applied: Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            case .deleted: Image(systemName: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
            case .moveTo: Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255)))
            case nil: EmptyView()
            }
        }
        .font(.body)
        .padding(5)
    }
}

private struct StatusPill: View {
    let status: Status
    var count: Int?

    var body: some View {
        Label {
            Text(count.map { "\($0) \(status.rawValue)" } ?? status.rawValue)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
        // A Capsule fills whatever height it is handed; without this the pill grows into
        // any spare room its row is given.
        .fixedSize()
        .tip(status.explanation)
    }

    private var icon: String {
        switch status {
        case .decrypted: return "lock.open.fill"
        case .renamed: return "textformat"
        case .locked: return "lock.fill"
        case .trashed: return "trash.fill"
        case .encrypted: return "lock.fill"
        case .moved: return "arrow.right.doc.on.clipboard"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// System greens and oranges sit around 2:1 on a light background, which is
    /// unreadable at caption size. These are darkened for light and lifted for dark.
    private var color: Color {
        switch status {
        case .decrypted: return Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
        case .renamed:   return Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
        case .locked:    return Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
        case .trashed:   return Color(light: srgb(88, 88, 96), dark: srgb(178, 178, 190))
        case .moved:     return Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
        case .encrypted: return Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
        case .failed:    return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
        }
    }
}

// MARK: - Bibliography

/// Mirrors NodeView, but each file shows what it will contribute to the .bib.
private struct BibNodeView: View {
    let node: Node
    @Binding var expanded: Set<String>
    @ObservedObject var runner: Runner

    var body: some View {
        if let key = node.itemKey, let entry = runner.bibByItem[key] {
            BibRow(entry: entry).tag(key).id(key)
        } else if node.itemKey == nil {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    BibNodeView(node: child, expanded: $expanded, runner: runner)
                }
            } label: {
                Label {
                    Text(node.name).fontWeight(.medium)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
                .onTapGesture { expansion.wrappedValue.toggle() }
            }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { open in
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
    }
}

private struct BibRow: View {
    let entry: BibEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(entry.isComplete
                                 ? Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
                                 : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.title.isEmpty ? "no title" : entry.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let author = entry.author {
                        Text(author).foregroundStyle(.secondary)
                    }
                    if let year = entry.year {
                        Text(year).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if !entry.missing.isEmpty {
                        Text("no " + entry.missing.joined(separator: ", "))
                            .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// The generated file. Entries are rendered one block at a time inside a LazyVStack, so
/// only what is on screen is ever tokenized: highlighting the whole document on every
/// redraw is what made this slow.
private struct BibFileView: View {
    let entries: [BibEntry]
    @Binding var order: BibOrder
    @Binding var completeOnly: Bool
    let style: BibStyle

    @AppStorage("bibWrapped") private var wrapped = true
    @State private var blocks: [String] = []
    @State private var edited: String?
    @State private var copied = false
    @State private var saving = false

    /// What Copy and Save write: the edit if there is one, otherwise the blocks joined.
    private var text: String {
        if let edited { return edited }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: style.blankLines ? "\n\n" : "\n") + "\n"
    }

    private var signature: String {
        [
            order.rawValue, "\(completeOnly)", "\(entries.count)",
            entries.first?.key ?? "", entries.last?.key ?? "",
            "\(style.lineWidth)", style.indent, "\(style.align)", style.delimiter.rawValue,
            "\(style.trailingComma)", "\(style.blankLines)", "\(style.sortFields)",
            "\(style.dropAllCaps)", style.omit.sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if edited != nil {
                TextEditor(text: Binding(get: { edited ?? "" }, set: { edited = $0 }))
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else if blocks.isEmpty {
                ContentUnavailableView("Nothing to write yet", systemImage: "text.quote")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Text(highlighted(block))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                // Wrapped, a long path folds into the pane instead of
                                // running off it. Unwrapped, the layout is the file's own.
                                .fixedSize(horizontal: !wrapped, vertical: false)
                        }
                    }
                    .padding(14)
                }
            }
        }
        // Rebuilt only when the inputs actually move, off the main thread.
        .task(id: signature) {
            let snapshot = entries
            let currentOrder = order
            let onlyComplete = completeOnly
            let currentStyle = style
            let built = await Task.detached(priority: .userInitiated) {
                bibtexOrdered(snapshot, includeIncomplete: !onlyComplete, order: currentOrder)
                    .map { bibtexBlock($0, style: currentStyle) }
            }.value
            guard !Task.isCancelled else { return }
            blocks = built
        }
        .fileExporter(isPresented: $saving,
                      document: BibDocument(text: text),
                      contentType: .plainText,
                      defaultFilename: "library.bib") { _ in }
    }

    private var controls: some View {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
            Picker("Order", selection: $order) {
                ForEach(BibOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(edited != nil)

            Toggle("Wrap", isOn: $wrapped)
                .toggleStyle(.checkbox)
                .tip("Fold long lines into the pane; the file itself is unchanged")
            Toggle("Complete only", isOn: $completeOnly)
                .toggleStyle(.checkbox)
                .disabled(edited != nil)

            if edited != nil {
                Label("Edited by hand", systemImage: "pencil")
                    .font(.callout)
                    .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                Button("Discard edits") { edited = nil }
                    .controlSize(.small)
                    .tip("Throw away your edits, back to the generated file")
            } else {
                Button("Edit") { edited = text }
                    .controlSize(.small)
                    .tip("Take the text over by hand; ordering freezes")
            }

            Spacer()

            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
            .controlSize(.small)
            Button("Save…") { saving = true }
                .controlSize(.small)
                .tip("Write the file somewhere")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
      .fixedSize(horizontal: false, vertical: true)
    }
}

/// Colours one block for reading. The tokens rebuild their input exactly, so what is
/// shown is character for character what Copy and Save produce.
private func highlighted(_ text: String) -> AttributedString {
    var out = AttributedString()
    for token in bibtexTokens(text) {
        var piece = AttributedString(token.text)
        switch token.kind {
        case .entryType:
            piece.foregroundColor = Color(light: srgb(142, 42, 152), dark: srgb(214, 137, 226))
            piece.font = .system(.callout, design: .monospaced).weight(.semibold)
        case .key:
            piece.foregroundColor = Color(light: srgb(29, 78, 216), dark: srgb(133, 174, 255))
            piece.font = .system(.callout, design: .monospaced).weight(.semibold)
        case .field:
            piece.foregroundColor = Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
        case .value:
            piece.foregroundColor = Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
        case .punctuation:
            piece.foregroundColor = .secondary
        case .plain:
            break
        }
        out += piece
    }
    return out
}

private struct BibDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}


// MARK: - Duplicates

/// One group of copies. The keeper is marked, every other copy offers to take its place,
/// and selecting any row shows it in the preview so two copies can be compared.
private struct DuplicateSection: View {
    let group: DuplicateGroup
    @ObservedObject var runner: Runner

    var body: some View {
        Section {
            ForEach(group.items) { item in
                DuplicateRow(
                    item: item,
                    isKeeper: item.key == group.keeper.key,
                    decision: runner.decision(for: item),
                    keep: { runner.keep(item, inGroup: group.id) }
                )
                .tag(item.key)
                .id(item.key)
            }
        } header: {
            HStack(spacing: 8) {
                Label(duplicateLabel(group.kind), systemImage: duplicateIcon(group.kind))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(duplicateColour(group.kind))
                    .help(duplicateExplanation(group.kind))
                Text("\(group.items.count) copies")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(group.reclaimable), countStyle: .file)
                     + " spare")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Trash the other \(group.extras.count)") {
                    runner.trashExtras(of: group.id)
                }
                .controlSize(.small)
                .tip("Keeps the starred copy, trashes the rest of this group")
                .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

func duplicateLabel(_ kind: DuplicateGroup.Kind) -> String {
    switch kind {
    case .identical: return "Identical"
    case .sameText: return "Same pages"
    case .likely: return "Similar names"
    }
}

func duplicateIcon(_ kind: DuplicateGroup.Kind) -> String {
    switch kind {
    case .identical: return "doc.on.doc.fill"
    case .sameText: return "text.magnifyingglass"
    case .likely: return "doc.on.doc"
    }
}

func duplicateColour(_ kind: DuplicateGroup.Kind) -> Color {
    switch kind {
    case .identical: return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
    case .sameText: return Color(light: srgb(109, 40, 217), dark: srgb(196, 165, 255))
    case .likely: return Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60))
    }
}

func duplicateExplanation(_ kind: DuplicateGroup.Kind) -> String {
    switch kind {
    case .identical: return "Byte for byte the same file"
    case .sameText: return "Different bytes, but the opening pages read the same"
    case .likely: return "Only the names agree, which is a guess"
    }
}

private struct DuplicateRow: View {
    let item: Item
    let isKeeper: Bool
    let decision: Decision?
    let keep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isKeeper ? "star.fill" : "circle")
                .foregroundStyle(isKeeper
                                 ? Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140))
                                 : Color.secondary.opacity(0.5))
                .padding(.top, 2)
                .help(isKeeper ? "The copy to keep" : "A spare copy")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(decision == .deleted)
                Text(item.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount ?? 0), countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if decision == .deleted {
                Label("Trash", systemImage: "trash.fill")
                    .font(.caption)
                    .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
            } else if !isKeeper {
                Button("Keep this one", action: keep)
                    .controlSize(.small)
                    .tip("Make this the copy the group keeps")
            }
        }
        .padding(.vertical, 3)
        .opacity(decision == .deleted ? 0.55 : 1)
    }
}

// MARK: - Sidebar rail

enum SidebarTab: String, CaseIterable, Identifiable {
    case sources, passwords, naming, files, ai, bibtex, reading, log, appearance

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sources: return "folder"
        case .passwords: return "key"
        case .naming: return "textformat"
        case .files: return "tray.full"
        case .ai: return "sparkles"
        case .bibtex: return "text.quote"
        case .reading: return "highlighter"
        case .log: return "list.bullet.rectangle"
        case .appearance: return "paintbrush"
        }
    }

    var title: String {
        switch self {
        case .sources: return "Sources"
        case .passwords: return "Passwords"
        case .naming: return "Name rules"
        case .files: return "Files"
        case .ai: return "AI"
        case .bibtex: return "BibTeX"
        case .reading: return "Reading"
        case .log: return "Activity"
        case .appearance: return "Appearance"
        }
    }
}

private struct RailButton: View {
    let tab: SidebarTab
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            Image(systemName: tab.icon)
                .font(.system(size: 15))
                .frame(width: 34, height: 32)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.15)
                              : hovering ? Color.secondary.opacity(0.12) : .clear)
                )
                // The marker an editor puts on the active tab.
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? Color.accentColor : .clear)
                        .frame(width: 2, height: 18)
                        .offset(x: -6)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(tab.title)
        .accessibilityLabel(tab.title)
    }
}

// MARK: - Shortcuts

/// Every key in one place, reachable with ? so it does not have to be remembered or
/// looked up outside the app.
private struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Deciding", [
            ("Return  C", "confirm the name and go to the next file"),
            ("E", "edit the name; Escape leaves the field"),
            ("G", "ask the model for a name"),
            ("B", "copy this file's BibTeX entry"),
            ("A", "apply this one file now"),
            ("S", "leave this file alone"),
            ("F", "leave the rest of this folder alone"),
            ("M", "move to another folder"),
            ("D", "move to the Trash on apply"),
            ("R", "reopen a decided file"),
        ]),
        ("Moving", [
            ("J  N  ↓", "next file; in the catalogue ↓ moves a whole row"),
            ("K  P  ↑", "previous file"),
            ("→  ←", "neighbour in the catalogue"),
        ]),
        ("Everything else", [
            ("⌘1 … ⌘4", "list, catalogue, BibTeX, duplicates"),
            ("⌘P", "preview"),
            ("⌘Return", "apply the reviewed plan"),
            ("⌘⇧Return", "confirm everything still pending"),
            ("⌘D", "find duplicates"),
            ("⌘R", "reveal in Finder"),
            ("O", "open in the default PDF viewer"),
            ("⌘Z", "undo the last decision"),
            ("⌘B", "show or hide the sidebar"),
            ("⌘⇧R", "reading mode: just the page"),
            ("⌘⇧N", "show or hide the notes beside the page"),
            ("⌘⇧T", "show or hide the table of contents"),
            ("?", "this list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(rows, id: \.0) { key, meaning in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(key)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 110, alignment: .leading)
                                    Text(meaning)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    Text("Letters work whenever the name field is not focused. Anything with "
                         + "Command works regardless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 560)
    }
}

/// Which panel the inspector's bottom pane shows.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case rename, details
    var id: String { rawValue }
    var label: String { self == .rename ? "Rename" : "Details" }
}

/// One highlight or note, in the rail beside the page.
private struct MarkRow: View {
    let mark: Annotator.Mark
    let isSelected: Bool
    let jump: () -> Void
    let remove: () -> Void
    let save: (String) -> Void
    let recolour: (NSColor) -> Void
    let styles: [HighlightStyle]
    let meaning: String

    @State private var editing = false
    @State private var text = ""

    /// The colour it was actually painted with, whatever palette that came from.
    private var colour: Color { Color(nsColor: mark.colour ?? .systemYellow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Menu {
                    ForEach(styles) { style in
                        Button { recolour(style.nsColor) } label: {
                            Label(style.meaning.isEmpty ? "Unnamed" : style.meaning,
                                  systemImage: "circle.fill")
                        }
                    }
                } label: {
                    Circle()
                        .fill(colour)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .padding(.top, 2)
                .tip(meaning)

                VStack(alignment: .leading, spacing: 3) {
                    if !mark.quoted.isEmpty {
                        // The quote carries the highlight it has on the page. A swatch
                        // says which colour; this says what the page looks like.
                        Text(mark.quoted)
                            .font(.callout)
                            .lineLimit(3)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(colour.opacity(0.38), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if !mark.note.isEmpty && !editing {
                        Text(mark.note).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    HStack(spacing: 5) {
                        Text("page \(mark.page)")
                        if !meaning.isEmpty && meaning != "Highlight" {
                            Text("·")
                            Text(meaning).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button {
                    text = mark.note
                    editing.toggle()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .tip(mark.note.isEmpty ? "Add a note here" : "Edit this note")
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .tip("Remove this mark from the file")
            }

            if editing {
                TextField("Note", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                HStack {
                    Button("Save") {
                        save(text)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Cancel") { editing = false }.controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: jump)
    }
}

/// The marks beside the page. A window-level pane like the sidebar, not part of the
/// inspector: nesting it inside a column that is already width-constrained made the two
/// of them overflow the frame and draw over the browser.
struct NotesRail: View {
    @ObservedObject var annotator: Annotator
    @ObservedObject var palette: Palette
    @Binding var addingNote: Bool
    @Binding var noteText: String
    let lastColour: NSColor
    let title: String
    let source: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").font(.callout.weight(.semibold))
                Spacer()
                Text("\(annotator.marks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !annotator.marks.isEmpty {
                    Menu {
                        Button("Copy as Markdown") { copyNotes() }
                        Button("Save as Markdown…") { exporting = true }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                    .tip("Export these notes")

                    Button(role: .destructive) { clearing = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                    .help("Remove every mark from this document")
                }
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .tip("Hide the notes", key: "⌘⇧N")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if addingNote {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Note on the selection")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("What is worth remembering", text: $noteText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...5)
                            HStack {
                                Button("Save") {
                                    annotator.highlightSelection(colour: lastColour, note: noteText)
                                    noteText = ""
                                    addingNote = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { noteText = ""; addingNote = false }
                            }
                        }
                        Divider()
                    }

                    if annotator.marks.isEmpty && !addingNote {
                        Text("Select text on the page to highlight it or attach a note.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(annotator.marks) { mark in
                        MarkRow(
                            mark: mark,
                            isSelected: annotator.selectedMark == mark.id,
                            jump: { annotator.jump(to: mark) },
                            remove: { annotator.remove(mark) },
                            save: { annotator.setNote($0, on: mark) },
                            recolour: { annotator.setColour($0, on: mark) },
                            styles: palette.styles,
                            meaning: palette.meaning(for: mark.colour)
                        )
                    }

                    if let problem = annotator.lastError {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background.secondary)
    }


    @State private var clearing = false
    @State private var exporting = false

    /// Reading notes as Markdown: the quotations, what was written about them, and where
    /// they are, which is the shape those notes take anywhere else they are pasted.
    private var notesMarkdown: String {
        markdownNotes(
            title: (title as NSString).deletingPathExtension,
            source: source,
            marks: annotator.marks.map {
                MarkExport(page: $0.page, quoted: $0.quoted, note: $0.note,
                           meaning: palette.meaning(for: $0.colour))
            }
        )
    }

    private func copyNotes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notesMarkdown, forType: .string)
    }
}

// MARK: - Metadata

/// What the file says about itself, under the actions that act on it.
///
/// Only what exists is shown. A grid of mostly-empty rows would push the useful line off
/// the bottom, and an absent field is not worth a row saying so.
private struct MetadataPanel: View {
    let item: Item
    let excerpt: String?

    private var facts: [(String, String)] {
        var rows: [(String, String)] = []
        for key in ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"] {
            if let value = item.documentInfo[key] { rows.append((key.lowercased(), value)) }
        }
        if let date = item.metadataDate {
            rows.append(("created", date.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }

    private var physical: String {
        [
            item.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            item.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" },
            item.modifiedDate.map { "modified \($0.formatted(date: .abbreviated, time: .omitted))" },
        ].compactMap { $0 }.joined(separator: "   ·   ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(physical)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if !facts.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(facts, id: \.0) { label, value in
                        GridRow {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .gridColumnAlignment(.trailing)
                            Text(value)
                                .font(.caption)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            } else if item.status == .locked {
                Label("Locked, so nothing inside can be read", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status

/// A thin line along the bottom for what the app is doing when nothing asked it to:
/// watching, taking in what turned up, or idle. Its own view so the pane's modifier chain
/// does not grow any further.
private struct StatusStrip: View {
    @ObservedObject var runner: Runner
    let watching: Bool

    private var absorbingText: String {
        runner.total > 0 ? "Reading \(runner.done) of \(runner.total) new files"
                         : "Checking what changed"
    }

    private var watchingText: String {
        let count = runner.lastAbsorbed
        guard count > 0 else { return "Watching for changes" }
        return "Watching. Last took in \(count) new file" + (count == 1 ? "." : "s.")
    }

    var body: some View {
        HStack(spacing: 8) {
            if runner.absorbing {
                ProgressView().controlSize(.small)
                Text(absorbingText)
            } else if watching {
                Image(systemName: "eye").foregroundStyle(.secondary)
                Text(watchingText)
            } else {
                Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                Text("Not watching")
            }
            Spacer()
            if runner.showingCached {
                Label("From last time", systemImage: "clock.arrow.circlepath")
            }
            Text("\(runner.results.count) files").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Contents

/// The document's own table of contents, on the page's left where a reader expects it.
/// Only offered when the PDF actually carries an outline.
struct ContentsRail: View {
    @ObservedObject var annotator: Annotator
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Contents").font(.callout.weight(.semibold))
                Spacer()
                Text("\(annotator.contents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .tip("Hide the contents", key: "⌘⇧T")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            List(annotator.contents) { chapter in
                Button {
                    annotator.go(to: chapter)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(chapter.label)
                            .font(chapter.level == 0 ? .callout.weight(.medium) : .caption)
                            .foregroundStyle(chapter.level == 0 ? .primary : .secondary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let page = chapter.page {
                            Text("\(page)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Depth by indent: a table of contents is read straight down far more
                    // often than it is folded.
                    .padding(.leading, CGFloat(chapter.level) * 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .listStyle(.inset)
        }
        .background(.background.secondary)
    }
}
