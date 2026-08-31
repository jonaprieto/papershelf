import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PaperShelfCore

private let bibGoodColor = Ink.green
private let bibWarnColor = Ink.amber

// MARK: - Real lookups

/// What the last lookup for a document did. Kept per item, not per entry: Runner rebuilds
/// its own entries from the filename and the AI guess on every scan, so this is the one
/// place a real fetch has anywhere to record what it found.
enum BibLookupStatus: Equatable {
    case idle
    case loading
    /// A registry answered.
    case found(MetadataSource)
    /// No registry knew this file; the model filled in what it could instead.
    case guessed
    /// Nothing knew it, not even the model.
    case notFound
}

/// Holds what a metadata lookup found, so both the entry list and the generated file can
/// show it. This view is the only one of the three that draws the bibliography tab that
/// this pass is allowed to touch, and the other two (BibRow, BibFileView) are instantiated
/// by Catalogue.swift, which this pass does not touch either -- there is no shared ancestor
/// view left to hold this state in instead. A single shared instance is the plain way
/// around that: every row and the file view all read the one lookup a person just ran.
///
/// `@MainActor` because everything it publishes is read by SwiftUI on the main actor, and
/// its own async work only ever leaves the actor for the network calls and PDF reads that
/// are genuinely off it, exactly the way Runner's own `identify(_:client:passwords:rules:)`
/// already does.
@MainActor
final class BibLookupStore: ObservableObject {
    static let shared = BibLookupStore()
    private init() {}

    @Published private(set) var status: [String: BibLookupStatus] = [:]
    @Published private(set) var metadata: [String: NormalizedMetadata] = [:]
    @Published private(set) var guesses: [String: BookGuess] = [:]
    @Published private(set) var reverted: [String: Set<String>] = [:]
    @Published private(set) var progress: (done: Int, total: Int)?

    private var batchTask: Task<Void, Never>?
    /// The real network, passed down exactly the way Metadata.swift's own doc comments ask
    /// for: every lookup function takes this instead of reaching for URLSession itself, so
    /// a test can hand it a stub.
    private let fetch: HTTPFetch = { try await URLSession.shared.data(for: $0) }

    /// The entry as it will actually render and export: a fetched record's fields layered
    /// over an AI guess's, layered over whatever `entry` already had, except any field this
    /// item's own person asked to keep. Pure and cheap, so views call it straight from
    /// `body` rather than caching a merged copy that could drift from a later fetch.
    func apply(to entry: BibEntry) -> BibEntry {
        var out = entry
        if let guess = guesses[entry.itemKey] {
            if out.title.isEmpty, !guess.title.isEmpty {
                out.title = guess.title
                out.fieldSources["title"] = .ai
            }
            if out.author == nil, let author = guess.author {
                out.author = author
                out.fieldSources["author"] = .ai
            }
            if out.year == nil, let year = guess.year {
                out.year = year
                out.fieldSources["year"] = .ai
            }
        }
        guard let record = metadata[entry.itemKey] else { return out }
        return applyFetchedMetadata(record, to: out, keeping: reverted[entry.itemKey] ?? [])
    }

    /// Puts one changed field back the way it was before a fetch touched it.
    func revert(_ field: String, for itemKey: String) {
        reverted[itemKey, default: []].insert(field)
    }

    func clear(_ itemKey: String) {
        metadata[itemKey] = nil
        guesses[itemKey] = nil
        reverted[itemKey] = nil
        status[itemKey] = nil
    }

    func cancelBatch() { batchTask?.cancel() }

    /// One document: look for a DOI or an arXiv id on its opening pages and ask the
    /// matching registry directly, since either one is a fact the registry can confirm.
    /// Failing that, try an ISBN for a book, then a Crossref title search. Only once every
    /// registry has come up empty does the configured model get asked, and only for
    /// title/author/year -- the fields it can plausibly read off a page, never a journal or
    /// a DOI it would otherwise have to invent.
    func lookUp(itemKey: String, url: URL, entry: BibEntry, passwords: [String], aiClient: AIClient) async {
        // A rapid double-click on the row's button fires this twice before SwiftUI has
        // swapped the button for a spinner; without this guard both calls would run their
        // own registry chain and, worst case, both fall through to a second, separately
        // billed AI call for the same document.
        guard status[itemKey] != .loading else { return }
        status[itemKey] = .loading
        defer { if status[itemKey] == .loading { status[itemKey] = .notFound } }

        let text = await Task.detached(priority: .userInitiated) {
            openingText(of: url, passwords: passwords, pages: 6)
        }.value

        if let doi = extractDOI(from: text), let work = try? await fetchDOI(doi, fetch: fetch) {
            resolve(work.normalized(), for: itemKey)
            return
        }
        if let arxivID = extractArxivID(from: text),
           let found = try? await fetchArxivEntry(id: arxivID, fetch: fetch) {
            resolve(found.normalized(), for: itemKey)
            return
        }
        if entry.type == .book, let isbn = extractISBN(from: text),
           let book = try? await fetchOpenLibraryBook(isbn: isbn, fetch: fetch) {
            resolve(book.normalized(), for: itemKey)
            return
        }
        if !entry.title.isEmpty,
           let results = try? await searchCrossref(bibliographic: entry.title, fetch: fetch),
           let best = results.first {
            resolve(best.normalized(), for: itemKey)
            return
        }

        guard !aiClient.apiKey.isEmpty,
              let guess = try? await aiClient.identify(filename: url.lastPathComponent, excerpt: text)
        else { return }
        guesses[itemKey] = guess
        status[itemKey] = .guessed
    }

    private func resolve(_ record: NormalizedMetadata, for itemKey: String) {
        metadata[itemKey] = record
        reverted[itemKey] = []
        status[itemKey] = .found(record.source)
    }

    /// Runs `lookUp` over every entry not already resolved, one at a time with a pause
    /// between requests: arXiv's own etiquette asks for three seconds between calls, and a
    /// burst of simultaneous requests to any of these registries risks getting this app's
    /// shared User-Agent throttled for everyone using it, not just this run. `url` maps an
    /// entry to where its file actually is; `bibEntries` already resolves `BibEntry.file`
    /// through `Item.currentURL`, so this is a plain read of that field, not a second
    /// lookup of its own.
    func lookUpBatch(_ entries: [BibEntry], url: @escaping (BibEntry) -> URL,
                      passwords: [String], aiClient: AIClient) {
        batchTask?.cancel()
        let queue = entries.filter { metadata[$0.itemKey] == nil && guesses[$0.itemKey] == nil }
        guard !queue.isEmpty else { return }
        progress = (0, queue.count)
        batchTask = Task { [weak self] in
            guard let self else { return }
            for (index, entry) in queue.enumerated() {
                if Task.isCancelled { break }
                await self.lookUp(itemKey: entry.itemKey, url: url(entry), entry: entry,
                                   passwords: passwords, aiClient: aiClient)
                self.progress = (index + 1, queue.count)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(1.2))
            }
            self.progress = nil
        }
    }
}

private func lookupSourceLabel(_ source: MetadataSource) -> String {
    switch source {
    case .doi: return "doi.org"
    case .crossref: return "Crossref"
    case .arxiv: return "arXiv"
    case .openLibrary: return "Open Library"
    }
}

/// Mirrors NodeView, but each file shows what it will contribute to the .bib.
/// The entries as the list draws them: one group per folder, in the order the entries
/// themselves are in.
///
/// A folder is a heading here rather than a disclosure triangle. A bibliography is read
/// straight down, and a folder you can fold is a folder that can hide the entry you were
/// looking for from a search that says it found it.
struct BibGroup: Identifiable {
    let name: String
    let entries: [BibEntry]
    var id: String { name }
}

/// Groups without reordering: the first entry decides where its folder appears, so the
/// order the entries arrive in is the order they are read in.
func bibGroups(_ entries: [BibEntry], folder: (BibEntry) -> String) -> [BibGroup] {
    var order: [String] = []
    var byFolder: [String: [BibEntry]] = [:]
    for entry in entries {
        let name = folder(entry)
        if byFolder[name] == nil { order.append(name) }
        byFolder[name, default: []].append(entry)
    }
    return order.map { BibGroup(name: $0, entries: byFolder[$0] ?? []) }
}

struct BibRow: View {
    let entry: BibEntry
    let item: Item?
    var passwords: [String] = []

    @ObservedObject private var lookup: BibLookupStore = .shared
    @ObservedObject private var kept: KeptBibtex = .shared
    @AppStorage("aiModel") private var aiModel = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var aiUseEnvironment = true
    @AppStorage("bibStandard") private var standard: BibStandard = .biblatex

    private var merged: BibEntry { lookup.apply(to: entry) }
    private var keptText: String? { kept.text(for: entry) }
    private var keptEntry: ParsedBibEntry? { keptText.flatMap(parseBibtexEntry) }
    private var gaps: [String] { bibGaps(entry, kept: kept, standard: standard) }
    private var status: BibLookupStatus { lookup.status[entry.itemKey] ?? .idle }
    private var changed: [String] { changedBibFields(entry, merged) }

    private var aiClient: AIClient {
        AIClient(baseURL: aiBaseURL, model: aiModel, apiKey: resolvedKey(useEnvironment: aiUseEnvironment))
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.step) {
            // The key first and on its own line: a .bib is read and cited by key, and it
            // is what every other view of this entry, the chips in the bar included,
            // calls it.
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(entry.key)
                    .font(Face.code)
                    .foregroundStyle(gaps.isEmpty ? Ink.blue : Ink.amber)
                    .lineLimit(1)
                    .truncationMode(.middle)

                credit

                // Said in the row that has the problem, in the words a person would use
                // about it, rather than as a field list: what is missing, and what will
                // go wrong because of it.
                if !gaps.isEmpty {
                    Text(shortfall)
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                lookupFooter
            }
            Spacer(minLength: Space.step)
            badge
            lookupButton
        }
        .padding(.vertical, Space.tight)
    }

    /// Author and title on one line, the way a bibliography is read.
    private var credit: some View {
        let author = keptEntry?.value("author") ?? merged.author
        let title = keptEntry?.value("title") ?? (merged.title.isEmpty ? "" : merged.title)
        return HStack(spacing: Space.tight) {
            Text(author ?? "")
                .lineLimit(1)
            Text("—").foregroundStyle(.tertiary)
            Text(title.isEmpty ? "no title" : title)
                .italic()
                .foregroundStyle(title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Face.control)
    }

    /// What the entry is, or what it is short of. One or the other: an entry that will
    /// not compile is not worth telling somebody it is a book.
    @ViewBuilder private var badge: some View {
        if let missing = gaps.first {
            Text("needs \(missing)")
                .font(Face.caption)
                .foregroundStyle(bibWarnColor)
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.hair)
                .fittedBackground(bibWarnColor.opacity(0.16), in: RoundedRectangle(cornerRadius: Metric.control))
                .help("Missing \(gaps.joined(separator: ", ")), which \(standard.label) requires")
        } else {
            Text("@\(keptEntry?.rawType ?? entry.type.rawValue)")
                .font(Face.mono)
                .foregroundStyle(bibGoodColor)
                .padding(.horizontal, Space.step)
                .padding(.vertical, Space.hair)
                .fittedBackground(bibGoodColor.opacity(0.16), in: RoundedRectangle(cornerRadius: Metric.control))
                .help(keptText == nil
                      ? "Complete for \(standard.label)"
                      : "Kept with the document, and complete for \(standard.label)")
        }
    }

    /// What is missing and what it costs, in one line.
    private var shortfall: String {
        let missing = gaps.joined(separator: ", ")
        if gaps == ["a readable entry"] { return "the entry kept here does not parse" }
        return "no \(missing) · \(standard.label) will complain"
    }

    @ViewBuilder private var lookupFooter: some View {
        switch status {
        case .found(let source):
            HStack(spacing: Space.tight) {
                Text(changed.isEmpty
                     ? "Looked up on \(lookupSourceLabel(source)), nothing new"
                     : "Filled in \(changed.joined(separator: ", ")) from \(lookupSourceLabel(source))")
                    .font(Face.micro)
                    .foregroundStyle(bibGoodColor)
                if !changed.isEmpty {
                    Menu("Keep original…") {
                        ForEach(changed, id: \.self) { field in
                            Button(field) { lookup.revert(field, for: entry.itemKey) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(Face.micro)
                    .fixedSize()
                }
            }
        case .guessed:
            Text("No registry knew this one; the model filled in what it could")
                .font(Face.micro)
                .foregroundStyle(.secondary)
        case .notFound:
            Text("No record found on doi.org, Crossref, arXiv or Open Library")
                .font(Face.micro)
                .foregroundStyle(.secondary)
        case .idle, .loading:
            EmptyView()
        }
    }

    @ViewBuilder private var lookupButton: some View {
        if status == .loading {
            ProgressView().controlSize(.small).padding(.top, Space.hair)
        } else if let item {
            Button {
                Task {
                    await lookup.lookUp(itemKey: entry.itemKey, url: item.currentURL, entry: entry,
                                        passwords: passwords, aiClient: aiClient)
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .tip("Look this up on doi.org, Crossref, arXiv or Open Library")
        }
    }
}

/// The generated file. Entries are rendered one block at a time inside a LazyVStack, so
/// only what is on screen is ever tokenized: highlighting the whole document on every
/// redraw is what made this slow.
struct BibFileView: View {
    let entries: [BibEntry]
    /// What the file would be called, after the source it was built from. The header says
    /// which file this is, and "library.bib" says that about every shelf equally.
    var name: String = "library.bib"
    @Binding var order: BibOrder
    @Binding var completeOnly: Bool
    let style: BibStyle
    var passwords: [String] = []

    @AppStorage("bibWrapped") private var wrapped = true
    @AppStorage("bibStandard") private var standard: BibStandard = .biblatex
    /// Deliberately separate from `completeOnly`: that toggle already means "this app's own
    /// title/author/year floor" to Catalogue.swift's own Markdown export, which reads the
    /// same @AppStorage key straight off `entry.isComplete`. Silently redefining what that
    /// key means here would make the same checkbox lie to whichever of the two screens
    /// last set it.
    @AppStorage("bibValidOnly") private var validOnly = false
    @AppStorage("aiModel") private var aiModel = "gpt-4o-mini"
    @AppStorage("aiBaseURL") private var aiBaseURL = "https://api.openai.com/v1"
    @AppStorage("aiUseEnvironment") private var aiUseEnvironment = true
    @ObservedObject private var lookup: BibLookupStore = .shared
    @ObservedObject private var kept: KeptBibtex = .shared
    @State private var blocks: [String] = []
    @State private var edited: String?
    @State private var confirmingLookup = false

    private var aiClient: AIClient {
        AIClient(baseURL: aiBaseURL, model: aiModel, apiKey: resolvedKey(useEnvironment: aiUseEnvironment))
    }

    /// Every entry as it will actually export: Runner's own build, with anything a lookup
    /// found laid on top.
    private var merged: [BibEntry] { entries.map { lookup.apply(to: $0) } }
    /// `completeOnly` is this app's own narrow floor (title/author/year); `validOnly` is
    /// the fuller, standard-accurate check. Independent toggles, so either can be used on
    /// its own or both together.
    private var shown: [BibEntry] {
        var out = merged
        if completeOnly { out = out.filter { kept.text(for: $0) != nil || $0.isComplete } }
        // A kept entry is judged by its own text, so an entry corrected by hand is not
        // filtered out by a check against the guess it replaced.
        if validOnly { out = out.filter { bibGaps($0, kept: kept, standard: standard).isEmpty } }
        return out
    }
    private var invalidCount: Int {
        merged.filter { !bibGaps($0, kept: kept, standard: standard).isEmpty }.count
    }
    /// What a batch run would actually fetch: everything not already resolved by an
    /// earlier lookup or guess.
    private var pendingLookupCount: Int {
        entries.filter { lookup.metadata[$0.itemKey] == nil && lookup.guesses[$0.itemKey] == nil }.count
    }

    /// What Copy and Save write: the edit if there is one, otherwise the blocks joined.
    private var text: String {
        if let edited { return edited }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: style.blankLines ? "\n\n" : "\n") + "\n"
    }

    private var signature: String {
        [
            order.rawValue, "\(completeOnly)", "\(validOnly)", "\(entries.count)",
            entries.first?.key ?? "", entries.last?.key ?? "",
            "\(style.lineWidth)", style.indent, "\(style.align)", style.delimiter.rawValue,
            "\(style.trailingComma)", "\(style.blankLines)", "\(style.sortFields)",
            "\(style.dropAllCaps)", style.omit.sorted().joined(separator: ","),
            standard.rawValue, "\(lookup.metadata.count)", "\(lookup.guesses.count)",
            "\(lookup.reverted.values.reduce(0) { $0 + $1.count })",
            // Keeping or improving an entry has to rebuild the file, or the change the
            // user just made is not in what they copy.
            "\(kept.byPath.count)", "\(kept.byPath.values.reduce(0) { $0 + $1.count })",
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if edited != nil {
                TextEditor(text: Binding(get: { edited ?? "" }, set: { edited = $0 }))
                    .font(Face.code)
                    .scrollContentBackground(.hidden)
                    .padding(Space.step)
            } else if blocks.isEmpty {
                ContentUnavailableView("Nothing to write yet", systemImage: "text.quote")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: Space.roomy) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Text(highlighted(block))
                                .font(Face.code)
                                .textSelection(.enabled)
                                // Wrapped, a long path folds into the pane instead of
                                // running off it. Unwrapped, the layout is the file's own.
                                .fixedSize(horizontal: !wrapped, vertical: false)
                        }
                    }
                    .padding(Space.roomy)
                }
            }
        }
        // Rebuilt only when the inputs actually move, off the main thread. `shown` is read
        // here, on the main actor, since it touches @Published lookup state; everything
        // after that is pure and safe to hand to a detached task.
        .task { await kept.refresh() }
        .task(id: signature) {
            let snapshot = shown
            let currentOrder = order
            let currentStyle = style
            let currentStandard = standard
            // The kept text is read here, on the main actor, since it is published state.
            let keptText = Dictionary(uniqueKeysWithValues: snapshot.compactMap { entry in
                kept.text(for: entry).map { (entry.itemKey, $0) }
            })
            let built = await Task.detached(priority: .userInitiated) {
                bibtexOrdered(snapshot, order: currentOrder).map { entry -> String in
                    // A kept entry is written out as it was kept. Rendering it from the
                    // generated fields would throw away everything a lookup or a person
                    // added to it, which is the whole reason it was kept.
                    if let text = keptText[entry.itemKey] {
                        let gaps = bibtexGaps(in: text, standard: currentStandard) ?? []
                        guard !gaps.isEmpty else { return text }
                        return "% \(entry.key) is missing " + gaps.joined(separator: ", ")
                            + " required by \(currentStandard.label)\n" + text
                    }
                    let block = bibtexBlock(entry, style: currentStyle)
                    guard let warning = bibtexValidationComment(for: entry, standard: currentStandard)
                    else { return block }
                    // Included anyway (Valid Only is off, or the group is satisfied some
                    // other way), but flagged right above it: a person pasting this in
                    // should not find out it does not compile from LaTeX instead.
                    return warning + "\n" + block
                }
            }.value
            guard !Task.isCancelled else { return }
            blocks = built
            BuiltBibliography.shared.text = text
        }
        .onChange(of: edited) { _, _ in BuiltBibliography.shared.text = text }
        .onDisappear { BuiltBibliography.shared.text = "" }
        .alert("Look up \(pendingLookupCount) documents?", isPresented: $confirmingLookup) {
            Button("Cancel", role: .cancel) {}
            Button("Look Up") {
                lookup.lookUpBatch(entries, url: { URL(fileURLWithPath: $0.file) },
                                    passwords: passwords, aiClient: aiClient)
            }
        } message: {
            Text("One request per document, to doi.org, Crossref, arXiv or Open Library, "
                 + "a couple of seconds apart. For anything none of those know, the opening "
                 + "pages go to your configured AI model instead, at its usual per-call cost. "
                 + "Cancel any time.")
        }
    }

    /// What the pane is showing, said once along its top: the file it would write, how
    /// much is in it, which standard decides what counts as complete, and how wide the
    /// lines are set. The controls that decide what is on screen live in the bar above
    /// both panes; what is left here is about this file.
    private var controls: some View {
      ScrollView(.horizontal) {
        HStack(spacing: Space.step) {
            Text(name)
                .font(Face.code)
                .foregroundStyle(.secondary)
            dot
            Text("\(shown.count) entries").foregroundStyle(.secondary)
            dot
            // A menu that reads as the label it is: the standard is a fact about this
            // file, and also the one thing here worth changing from here.
            Menu(standard.label) {
                ForEach(BibStandard.allCases) { option in
                    Button(option.label) { standard = option }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .tip("Which fields count as required: classic BibTeX or biblatex")
            dot
            Text("\(style.lineWidth) columns").foregroundStyle(.secondary)

            Spacer(minLength: Space.roomy)

            lookupControl

            if edited != nil {
                Label("Edited by hand", systemImage: "pencil")
                    .foregroundStyle(bibWarnColor)
                Button("Discard edits") { edited = nil }
                    .controlSize(.small)
                    .tip("Throw away your edits, back to the generated file")
            } else {
                Button("Edit") { edited = text }
                    .controlSize(.small)
                    .tip("Take the text over by hand; ordering freezes")
            }
        }
        .font(Face.control)
        .padding(.horizontal, Space.roomy)
        .padding(.vertical, Space.snug)
      }
      .scrollIndicators(.hidden)
      .fixedSize(horizontal: false, vertical: true)
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    @ViewBuilder private var lookupControl: some View {
        if let progress = lookup.progress {
            HStack(spacing: Space.snug) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 80)
                Text("\(progress.done)/\(progress.total)").font(Face.caption).monospacedDigit()
                Button("Cancel") { lookup.cancelBatch() }.controlSize(.small)
            }
        } else {
            Button("Look Up All") { confirmingLookup = true }
                .controlSize(.small)
                .disabled(pendingLookupCount == 0)
                .tip("Fetch a real record for each entry from doi.org, Crossref, arXiv or Open Library")
        }
    }

}

/// What the bar says about the entries that are not ready yet.
///
/// One sentence, and it names the field when the whole set is short of the same one,
/// because "3 entries need an author" is a thing a person can act on and "3 incomplete"
/// is a thing they have to go and investigate.
struct BibGaps {
    /// Entry keys, in the order they are drawn, each with what it is missing.
    let byEntry: [(key: String, itemKey: String, missing: [String])]
    let standard: BibStandard

    var count: Int { byEntry.count }
    var isEmpty: Bool { byEntry.isEmpty }

    /// The one field everything is missing, when there is one.
    var sharedField: String? {
        let fields = Set(byEntry.flatMap(\.missing))
        return fields.count == 1 ? fields.first : nil
    }

    var sentence: String {
        let subject = count == 1 ? "entry needs" : "entries need"
        if let field = sharedField { return "\(count) \(subject) \(article(for: field)) \(field)" }
        return "\(count) \(count == 1 ? "entry is" : "entries are") missing fields "
            + "\(standard.label) requires"
    }

    private func article(for field: String) -> String {
        "aeiou".contains(field.lowercased().first ?? "x") ? "an" : "a"
    }
}

@MainActor
func bibGaps(in entries: [BibEntry], kept: KeptBibtex, standard: BibStandard) -> BibGaps {
    BibGaps(byEntry: entries.compactMap { entry in
        let missing = bibGaps(entry, kept: kept, standard: standard)
        return missing.isEmpty ? nil : (entry.key, entry.itemKey, missing)
    }, standard: standard)
}

/// One entry that is not ready, as a chip in the bar: the key, and a way into it.
///
/// A count on its own says how much is wrong and nothing about where. These are the
/// entries themselves, so the way to the problem is the thing that reports it.
struct BibGapChip: View {
    let key: String
    let missing: [String]
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.tight) {
                Text(key)
                    .font(Face.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right").font(Face.micro)
            }
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.tight)
            .fittedBackground(Ink.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: Metric.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.amber)
        .tip("Missing \(missing.joined(separator: ", ")). Go to this entry.")
        .accessibilityLabel("\(key), missing \(missing.joined(separator: ", "))")
    }
}

/// Asks the model to fill in what the standard is short of, for every entry that is short
/// of something. The confirmation lives with the button rather than with whichever pane
/// happens to draw it, so there is one description of what this costs.
struct FillGapsButton: View {
    let entries: [BibEntry]
    let passwords: [String]
    let client: AIClient
    let standard: BibStandard
    let style: BibStyle

    @ObservedObject private var batch: BibtexBatch = .shared
    @ObservedObject private var kept: KeptBibtex = .shared
    @State private var confirming = false

    private var ready: Bool { !client.apiKey.isEmpty }

    var body: some View {
        if let running = batch.progress {
            HStack(spacing: Space.snug) {
                ProgressView(value: Double(running.done), total: Double(max(running.total, 1)))
                    .frame(width: 80)
                Text("\(running.done)/\(running.total)").font(Face.caption).monospacedDigit()
                Button("Stop") { batch.cancel() }.controlSize(.small)
            }
        } else {
            Button { confirming = true } label: {
                Label("Fill the \(entries.count) gap\(entries.count == 1 ? "" : "s") with AI",
                      systemImage: "sparkles")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(entries.isEmpty || !ready)
            .tip(ready
                 ? "Ask the model to fill in what \(standard.label) is missing. One billed "
                   + "request per entry, kept as they arrive."
                 : "Needs an API key, in Settings")
            .confirmationDialog("Fill \(entries.count) gaps with AI?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Ask") {
                    batch.run(entries, client: client, passwords: passwords,
                              library: Library.shared, kept: kept, standard: standard,
                              text: { kept.text(for: $0) ?? bibtexBlock($0, style: style) })
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("One billed request per entry, sending the entry and the first pages "
                     + "of the document to \(client.baseURL). Each answer is kept with its "
                     + "document as it arrives, so stopping partway keeps what it already "
                     + "did. A model can be confidently wrong: check the entries after.")
            }
        }
    }
}

/// The bibliography as it currently stands, so the window's toolbar can copy or save it
/// without building the same text a second time.
///
/// Published state rather than a binding threaded through four views: the file is built
/// in one place, by the pane that draws it, and the toolbar is simply another reader of
/// the same answer.
@MainActor
final class BuiltBibliography: ObservableObject {
    static let shared = BuiltBibliography()
    @Published var text = ""
    var isEmpty: Bool { text.isEmpty }
}

/// Colours one block for reading. The tokens rebuild their input exactly, so what is
/// shown is character for character what Copy and Save produce.
func highlighted(_ text: String) -> AttributedString {
    var out = AttributedString()
    for token in bibtexTokens(text) {
        var piece = AttributedString(token.text)
        switch token.kind {
        case .entryType:
            piece.foregroundColor = Ink.magenta
            piece.font = .system(.callout, design: .monospaced).weight(.semibold)
        case .key:
            piece.foregroundColor = Ink.blue
            piece.font = .system(.callout, design: .monospaced).weight(.semibold)
        case .field:
            piece.foregroundColor = Ink.amber
        case .value:
            piece.foregroundColor = Ink.green
        case .punctuation:
            piece.foregroundColor = .secondary
        case .plain:
            break
        }
        out += piece
    }
    return out
}

// MARK: - Entries the user decided on

/// The kept entries, shared by everything that shows a citation.
///
/// A generated entry is a guess read off a filename; a kept one is what somebody decided,
/// possibly after fetching it from a registry or correcting it by hand. Wherever both
/// exist, the kept one is the truth, and the bibliography was showing the guess: thirty
/// entries reported as missing an author while the entry kept beside the document had
/// four of them.
@MainActor
final class KeptBibtex: ObservableObject {
    static let shared = KeptBibtex()

    @Published private(set) var byPath: [String: String] = [:]

    func refresh() async {
        guard let library = Library.shared else { return }
        byPath = (try? await library.storedBibtexByPath()) ?? [:]
    }

    /// A document is known at more than one path once it has been renamed: `itemKey` is
    /// where the file started and `file` is where it is going, so both are tried, each
    /// also with symlinks resolved, since the store records resolved paths and an entry
    /// may not be holding one.
    func text(for entry: BibEntry) -> String? {
        for path in [entry.itemKey, entry.file] {
            if let found = byPath[path] { return found }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let found = byPath[resolved] { return found }
        }
        return nil
    }

    /// After storing, so every other view showing this entry catches up without a reload.
    func remember(_ entry: String, at paths: [String]) {
        for path in paths { byPath[path] = entry }
    }

    func forget(_ paths: [String]) {
        for path in paths { byPath[path] = nil }
    }
}

/// What an entry is missing, judged from the kept text when there is one.
@MainActor
func bibGaps(_ entry: BibEntry, kept: KeptBibtex, standard: BibStandard) -> [String] {
    guard let text = kept.text(for: entry) else { return entry.gaps(for: standard) }
    // Text that does not parse is not silently called valid.
    return bibtexGaps(in: text, standard: standard) ?? ["a readable entry"]
}
