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
            CommandGroup(after: .sidebar) {
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

        let url = item.source
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
    case list, catalogue, bibliography
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .catalogue: return "Catalogue"
        case .bibliography: return "BibTeX"
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .catalogue: return "square.grid.2x2"
        case .bibliography: return "text.quote"
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
    @Published private(set) var confirmedCount = 0
    @Published private(set) var appliedCount = 0
    /// Bumped whenever the suggested names change without the list itself changing.
    @Published private(set) var revision = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var deletedCount = 0

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

    private var jobs: [Job] = []

    var busy: Bool { phase != .idle }
    var reviewed: Int { confirmedCount + appliedCount + skippedCount + deletedCount }
    var pendingCount: Int { results.count - reviewed }
    var allReviewed: Bool { lastRunWasDry && !results.isEmpty && pendingCount == 0 }
    /// What a batch Apply would still touch. Files already applied are done.
    var actionable: Int { confirmedCount + deletedCount }

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
        results = PDFHammerCore.restyled(results, options: options)
        revision += 1
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
        set(.confirmed(sanitizedFilename(name)), for: item.key)
    }

    func skip(_ item: Item) { set(.skipped, for: item.key) }
    func markForDeletion(_ item: Item) { set(.deleted, for: item.key) }

    func reopen(_ item: Item) {
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

    private func tally(_ decision: Decision?, by delta: Int) {
        switch decision {
        case .confirmed: confirmedCount += delta
        case .applied: appliedCount += delta
        case .skipped: skippedCount += delta
        case .deleted: deletedCount += delta
        case nil: break
        }
    }

    /// Accepts every suggestion still waiting, for when reviewing thousands of files one
    /// at a time is not what you came here for.
    func confirmAllPending() {
        for item in results where decisions[item.key] == nil {
            decisions[item.key] = .confirmed(item.destinationName)
            confirmedCount += 1
        }
        cursor = results.count
    }

    func skipFolder(of item: Item) {
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
    }

    /// Updates one row in place. The tree holds keys, so it needs no rebuilding.
    private func replace(_ key: String, with item: Item) {
        guard let index = indexByKey[key] else { return }
        let previous = results[index].status
        results[index] = item
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
    }

    func findDuplicates() {
        guard !results.isEmpty, !findingDuplicates else { return }
        findingDuplicates = true
        let snapshot = results
        Task.detached(priority: .userInitiated) { [self] in
            let found = duplicateGroups(in: snapshot)
            await MainActor.run {
                self.duplicates = found
                self.duplicateKind = Dictionary(
                    uniqueKeysWithValues: found.flatMap { group in
                        group.items.map { ($0.key, group.kind) }
                    }
                )
                self.findingDuplicates = false
            }
        }
    }

    /// Marks the spare copies of byte-identical files for the Trash, keeping the best of
    /// each. Only identical groups: a likely match is a guess, and guesses do not get to
    /// delete a book on their own.
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

        let source = item.source
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

    func preview(roots: [URL], options: Options, fingerprint: String) {
        begin(fingerprint: fingerprint, dry: true)

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
            await MainActor.run { self.finish(out) }
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
        for (key, decision) in decisions {
            switch decision {
            case .confirmed(let name): overrides[key] = name
            case .deleted: trashed.insert(key)
            case .skipped, .applied, nil: break
            }
        }

        begin(fingerprint: fingerprint, dry: false)
        total = queue.count

        Task.detached(priority: .userInitiated) { [self] in
            await MainActor.run { self.phase = .processing }
            let out = process(jobs: queue, options: options, overrides: overrides,
                              trashed: trashed, progress: self.report)
            await MainActor.run { self.finish(out) }
        }
    }

    private func begin(fingerprint: String, dry: Bool) {
        phase = dry ? .scanning : .processing
        results = []
        tree = []
        statusCounts = []
        byFolder = [:]
        indexByKey = [:]
        ancestorsByKey = [:]
        duplicates = []
        duplicateKind = [:]
        guesses = [:]
        decisions = [:]
        confirmedCount = 0
        appliedCount = 0
        skippedCount = 0
        deletedCount = 0
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
    private func finish(_ out: [Item]) {
        results = out
        tree = buildTree(out)

        var counts: [Status: Int] = [:]
        var folders: [String: [Int]] = [:]
        var keys: [String: Int] = [:]
        for (index, item) in out.enumerated() {
            counts[item.status, default: 0] += 1
            folders[folderPath(of: item), default: []].append(index)
            keys[item.key] = index
        }
        indexByKey = keys

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
        ancestorsByKey = ancestors
        statusCounts = Status.allCases.compactMap { status in
            counts[status].map { (status, $0) }
        }
        byFolder = folders

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
    @State private var choosingBackupFolder = false
    @AppStorage("useFolderNames") private var useFolderNames = true
    @AppStorage("useMetadataDate") private var useMetadataDate = false
    @AppStorage("useFileDate") private var useFileDate = false
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("ruleCasing") private var ruleCasing: NameRules.Casing = .lowercase
    @AppStorage("ruleSeparator") private var ruleSeparator: NameRules.Separator = .keep
    @AppStorage("ruleStripSymbols") private var ruleStripSymbols = false
    @AppStorage("ruleStripDiacritics") private var ruleStripDiacritics = false

    @AppStorage("sources") private var storedSources = ""
    @AppStorage("autoPreview") private var autoPreview = true

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

    private var rules: NameRules {
        NameRules(casing: ruleCasing, separator: ruleSeparator,
                  stripSymbols: ruleStripSymbols, stripDiacritics: ruleStripDiacritics)
    }

    /// Exercises every rule at once, so the footer shows what each switch actually does.
    private static let sampleName = "Extracto Señor_Acme 66 (1)_23_08_2026.pdf"

    private func options(dryRun: Bool) -> Options {
        // Subfolders are always included; the preview shows exactly what that reaches.
        Options(passwords: passwords, recursive: true, dryRun: dryRun,
                backup: backup, useFolderNames: useFolderNames,
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
        ].joined(separator: "\u{1}")
    }

    /// What only changes the names. These are answered from dates already captured, so
    /// the list restyles itself instead of asking for another preview.
    private var namingFingerprint: String {
        [
            "\(useFolderNames)", "\(useMetadataDate)", "\(useFileDate)",
            ruleCasing.rawValue, ruleSeparator.rawValue,
            "\(ruleStripSymbols)", "\(ruleStripDiacritics)",
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
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
        .onAppear {
            sizeWindowOnFirstLaunch()
            NSApp.appearance = appearance.nsAppearance
            restoreSources()
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

    private var sidebar: some View {
        Form {
            Section("Sources") {
                if selection.isEmpty {
                    Text("Nothing selected")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(selection, id: \.self) { url in
                        SourceRow(url: url) {
                            selection.removeAll { $0 == url }
                            persistSources()
                        }
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
                }
            }

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
                        .help("Remove this password")
                        .accessibilityLabel("Remove password \(index + 1)")
                    }
                }
                Button(action: addPassword) {
                    Label("Add password", systemImage: "plus.circle")
                }
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

            Section {
                Picker("Case", selection: $ruleCasing) {
                    ForEach(NameRules.Casing.allCases) { Text($0.label).tag($0) }
                }
                Picker("Separators", selection: $ruleSeparator) {
                    ForEach(NameRules.Separator.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Remove symbols", isOn: $ruleStripSymbols)
                Toggle("Remove accents", isOn: $ruleStripDiacritics)
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

            Section {
                Toggle("Use the folder name", isOn: $useFolderNames)
                Toggle("Use the PDF's creation date", isOn: $useMetadataDate)
                Toggle("Use the file's modification date", isOn: $useFileDate)
            } header: {
                Text("When the filename has no date")
            } footer: {
                Text("Tried in this order. A date already in the filename always wins, "
                     + "since it is the only one the document itself states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep the originals", isOn: $moveOriginals)
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

            Section("Running") {
                Toggle("Preview as soon as a source is added", isOn: $autoPreview)
            }

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if !moveOriginals {
                Section {
                    Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                         text: "Applying will replace the originals. Nothing is kept and there is no undo.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("API key, model and endpoint")
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
            .disabled(selection.isEmpty || runner.busy)
            .keyboardShortcut("p", modifiers: .command)

            Button(action: confirmApply) {
                Label(canApply ? "Apply to \(runner.actionable) files" : "Apply",
                      systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canApply)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    /// The selection is a set of non-overlapping roots: a folder absorbs anything already
    /// picked inside it, and nothing already covered is added twice.
    private func add(_ urls: [URL]) {
        let before = selection
        selection = mergedSources(selection, adding: urls)
        guard selection.map(\.path) != before.map(\.path) else { return }
        persistSources()
        if autoPreview { preview() }
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
    @State private var confirmingBatchAI = false
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
        Group {
            if runner.busy {
                busyState
            } else if runner.results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    summaryBar
                    Divider()
                    HSplitView {
                        browser.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                        inspector.frame(minWidth: 340, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($paneFocused)
        .animation(.easeOut(duration: 0.18), value: runner.results.count)
        .onChange(of: runner.results.count) { _, _ in ensureSelection() }
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
        .onDisappear(perform: removeKeyMonitor)
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
        .alert("The service could not be reached",
               isPresented: Binding(get: { runner.aiError != nil },
                                    set: { if !$0 { runner.aiError = nil } })) {
            Button("OK") { runner.aiError = nil }
        } message: {
            Text(runner.aiError ?? "")
        }
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
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }

        // Anything being typed into, or any control that has its own idea of what a key
        // means, keeps the event. A table view does not: its type-select is what we are
        // deliberately replacing.
        if let responder = event.window?.firstResponder,
           responder is NSTextView || (responder is NSControl && !(responder is NSTableView)) {
            return false
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\r", "c": confirm()
        case "e": editingName = true
        case "s": skip()
        case "f": skipFolder()
        case "a": applyNow()
        case "g": identifySelected()
        case "d": markDeleted()
        case "r": reopenSelected()
        case "j", "n": step(by: 1)
        case "k", "p": step(by: -1)
        default: return false
        }
        return true
    }

    private func loadDraft() {
        editingName = false
        draft = selectedItem.map(currentName) ?? ""
        suggestion = selectedItem?.destinationName ?? ""
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
    private func step(by offset: Int) {
        guard let current = runner.results.firstIndex(where: { $0.key == selected }) else { return }
        let next = current + offset
        guard runner.results.indices.contains(next) else { return }
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
        }
    }

    /// The whole selection flattened into one .bib, rebuilt from the current names on
    /// every change, so it always describes what Apply would produce.
    private var bibliography: some View {
        BibliographyView(
            entries: bibEntries(for: runner.results, known: runner.guesses),
            selected: $selected
        )
    }

    /// A shelf of covers. `LazyVGrid` only builds what is on screen, and the cover store
    /// only renders what is built, so the cost follows the window and not the collection.
    private var catalogue: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 18)],
                          alignment: .leading, spacing: 18) {
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

    private var list: some View {
        ScrollViewReader { scroll in
            List(selection: $selected) {
                ForEach(runner.tree) { node in
                    NodeView(node: node, expanded: $expanded, runner: runner)
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
                aiReady: aiReady,
                markDeleted: markDeleted,
                reopen: reopenSelected,
                reset: { draft = item.destinationName },
                leaveField: { editingName = false; listFocused = true }
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
        if !runner.results.isEmpty { listFocused = true }
    }

    // MARK: Header

    private var summaryBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(runner.statusCounts, id: \.0) { status, count in
                    StatusPill(status: status, count: count)
                }
                Spacer(minLength: 12)
                stateLabel
            }
            if runner.lastRunWasDry {
                HStack(spacing: 10) {
                    Picker("View", selection: $mode) {
                        ForEach(ViewMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)

                    duplicateControls
                    if aiReady && runner.pendingCount > 0 {
                        Button("Ask AI for \(runner.pendingCount) names") { confirmingBatchAI = true }
                            .controlSize(.small)
                    }
                    Divider().frame(height: 16)
                }
                HStack(spacing: 10) {
                    ProgressView(value: Double(runner.reviewed),
                                 total: Double(max(runner.results.count, 1)))
                        .frame(maxWidth: 220)
                    if runner.pendingCount == 0 {
                        Label("All \(runner.results.count) reviewed, Apply is unlocked",
                              systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
                    } else {
                        Text("\(runner.reviewed) of \(runner.results.count) reviewed")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Confirm all remaining") {
                        runner.confirmAllPending()
                        ensureSelection()
                    }
                    .controlSize(.small)
                    .disabled(runner.pendingCount == 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
            let likely = runner.duplicates.count - identical
            Text("\(identical) identical, \(likely) likely")
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
    let aiReady: Bool
    let markDeleted: () -> Void
    let reopen: () -> Void
    let reset: () -> Void
    let leaveField: () -> Void

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
            PDFPreview(url: item.source, passwords: passwords)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.35))
                .overlay(alignment: .topTrailing) { lockedOverlay }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusPill(status: item.status, count: nil)
                    if runner.isThinking(item) {
                        ProgressView().controlSize(.small)
                    }
                    Text(folderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(minWidth: 0)
                    Spacer(minLength: 8)
                    decisionBadge
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("New name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(action: confirm) { KeyLabel("\u{21A9}", "Confirm") }
                        .buttonStyle(.borderedProminent)
                    Button(action: { editing = true }) { KeyLabel("E", "Edit name") }
                    Button(action: applyNow) { KeyLabel("A", "Apply now") }
                        .disabled(decision == .applied)
                        .help("Rename this one file right now, without waiting for the batch")
                    Button(action: identify) { KeyLabel("G", "Ask AI") }
                        .disabled(!aiReady || runner.isThinking(item))
                        .help(aiReady
                              ? "Read the opening pages and suggest a title"
                              : "Add an API key in Settings first")
                    Button(action: skip) { KeyLabel("S", "Skip") }
                    Button(action: skipFolder) {
                        KeyLabel("F", folderScopeLabel)
                    }
                    .disabled(pendingInFolder == 0)
                    .help("Skip everything still undecided in \(folderName) and below it")
                    if decision != nil {
                        Button(action: reopen) { KeyLabel("R", "Reopen") }
                    }
                    Spacer(minLength: 0)

                    // Kept apart from the others: it is the one action with consequences.
                    Divider().frame(height: 18)
                    Button(action: markDeleted) { KeyLabel("D", "Delete") }
                        .tint(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
                }
                .controlSize(.large)

                Text(decision == .deleted
                     ? "Moves to the Trash on apply, so it stays recoverable. R puts it back."
                     : "J or N next file, K or P previous, without deciding. F skips the rest of \(folderName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if draft.isEmpty { draft = item.destinationName } }
        .onChange(of: item.key) { _, _ in editing = false }
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

    func makeNSView(context: Context) -> FitWidthPDFView {
        let view = FitWidthPDFView()
        // autoScales fits the whole page and centres it, which is the opposite of what a
        // page of text wants.
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
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
    }
}

private struct NodeView: View {
    let node: Node
    @Binding var expanded: Set<String>
    @ObservedObject var runner: Runner

    var body: some View {
        if let key = node.itemKey, let item = runner.item(key) {
            ResultRow(item: item, decision: runner.decision(for: item),
                      duplicate: runner.duplicateKind[item.key])
                .tag(key)
                .id(key)
        } else {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children ?? []) { child in
                    NodeView(node: child, expanded: $expanded, runner: runner)
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
                Image(systemName: duplicate == .identical ? "doc.on.doc.fill" : "doc.on.doc")
                    .foregroundStyle(duplicate == .identical
                                     ? Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
                                     : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    .help(duplicate == .identical ? "Byte-identical copy" : "Probably the same book")
            }
        }
        .padding(.vertical, 3)
        .opacity(decision == .skipped ? 0.45 : 1)
    }

    private var shownName: String {
        if case .confirmed(let name) = decision { return name }
        return item.destinationName
    }

    @ViewBuilder
    private var reviewMark: some View {
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
                Image(systemName: duplicate == .identical ? "doc.on.doc.fill" : "doc.on.doc")
                    .foregroundStyle(duplicate == .identical
                                     ? Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
                                     : Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                    .help(duplicate == .identical
                          ? "Byte-identical copy of another file here"
                          : "Probably the same book as another file here")
            }
            switch decision {
            case .confirmed: Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
            case .applied: Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color(light: srgb(21, 111, 58), dark: srgb(104, 219, 140)))
            case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            case .deleted: Image(systemName: "trash.circle.fill")
                .foregroundStyle(Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130)))
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
    }

    private var icon: String {
        switch status {
        case .decrypted: return "lock.open.fill"
        case .renamed: return "textformat"
        case .locked: return "lock.fill"
        case .trashed: return "trash.fill"
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
        case .failed:    return Color(light: srgb(176, 29, 29), dark: srgb(248, 130, 130))
        }
    }
}

// MARK: - Bibliography

/// The generated .bib alongside the gaps in it. Everything is derived from the current
/// results, so it follows renames and AI answers without a refresh button.
private struct BibliographyView: View {
    let entries: [BibEntry]
    @Binding var selected: String?

    @State private var completeOnly = false
    @State private var copied = false
    @State private var saving = false

    private var shown: [BibEntry] { completeOnly ? entries.filter(\.isComplete) : entries }
    private var document: String { bibtexDocument(entries, includeIncomplete: !completeOnly) }
    private var incomplete: [BibEntry] { entries.filter { !$0.isComplete } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(shown.count) entries").font(.callout).foregroundStyle(.secondary)
                if !incomplete.isEmpty {
                    Label("\(incomplete.count) missing fields", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color(light: srgb(163, 88, 8), dark: srgb(251, 191, 60)))
                        .help("Ask AI on those files to fill in author and year")
                }
                Spacer()
                Toggle("Complete only", isOn: $completeOnly).toggleStyle(.checkbox)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .controlSize(.small)
                Button("Save…") { saving = true }.controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if incomplete.isEmpty == false && completeOnly == false {
                gaps
                Divider()
            }

            ScrollView([.vertical, .horizontal]) {
                Text(document.isEmpty ? "Nothing to write yet." : document)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .fileExporter(isPresented: $saving,
                      document: BibDocument(text: document),
                      contentType: .plainText,
                      defaultFilename: "library.bib") { _ in }
    }

    /// The entries that need a hand, clickable so the file can be dealt with.
    private var gaps: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(incomplete) { entry in
                    Button {
                        selected = entry.itemKey
                    } label: {
                        Text("\(entry.key) · no \(entry.missing.joined(separator: ", "))")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }
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
