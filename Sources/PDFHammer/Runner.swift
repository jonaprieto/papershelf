import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

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
        // Applying one file on its own never reaches `finish`, and it moves the file just
        // as a whole run does, so the library has to hear about this one too.
        Task { await self.syncLibrary(with: [done]) }
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
        case .trashed: return .trashed
        case .failed: return .failed
        case .locked: return .renamed
        // Both rewrite the file, and the log has one word for that.
        case .encrypted: return .decrypted
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

        // Every path that produces results ends here: a preview, a real run, and the
        // watcher absorbing what changed on disk. One call covers all three, and it is the
        // call that keeps a renamed document's tags, notes and project membership attached
        // to it rather than orphaned at a path that no longer exists.
        Task { await self.syncLibrary(with: out) }
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
