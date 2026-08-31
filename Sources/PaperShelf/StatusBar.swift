import SwiftUI
import PaperShelfCore

/// The strip along the bottom of the window.
///
/// The app had nowhere to put anything transient, so progress, counts and the state label
/// lived in a second row of the results bar that appeared and disappeared — which meant
/// the toolbar changed shape while work was running and the content below it jumped. All
/// of that lives here now, in a bar that is always exactly one line tall.
/// When a document was last opened, said the way a person would. Exact dates are for a
/// file listing; a status bar is answering "have I read this recently".
func openedLabel(_ date: Date, now: Date = Date()) -> String {
    let seconds = now.timeIntervalSince(date)
    switch seconds {
    case ..<0: return "opened just now"
    case ..<3600: return "opened in the last hour"
    case ..<86_400: return "opened today"
    case ..<172_800: return "opened yesterday"
    case ..<2_592_000: return "opened \(Int(seconds / 86_400)) days ago"
    case ..<31_536_000: return "opened \(max(1, Int(seconds / 2_592_000))) months ago"
    default: return "opened \(max(1, Int(seconds / 31_536_000))) years ago"
    }
}

/// One line, one height, one background, whichever of the two bars is drawn.
private struct StatusBarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Face.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, Space.roomy)
            .frame(height: Metric.statusBar)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .region(.status)
    }
}

struct StatusBar: View {
    var runner: Runner
    /// Observed on its own: these are the numbers that move several times a second, and
    /// this bar is one of the two places that show them.
    var activity: Activity
    let watching: Bool
    let sources: Int
    let unavailableSources: Int
    /// Already formatted by the caller: money carries its currency and is never coerced
    /// into a Double on the way to a label.
    let spend: String?
    /// Whether the plan on screen still describes the settings it was built with. It was
    /// a label in the results bar; it belongs with everything else that is about right
    /// now rather than about the collection.
    let planIsCurrent: Bool
    /// Where the selected file is. The one fact about a document that fits nowhere else:
    /// a card shows a name, the inspector shows what is in it, and neither has room for
    /// three folders and a filename.
    let selectedPath: String?
    /// When that file was last read, or nil for one nobody has opened.
    let lastOpened: Date?
    /// What the bibliography holds, when that is what is on screen: how many entries, how
    /// many are short of what the standard wants, and whether any two share a key. Nil in
    /// every other view, which is the only way the bar says nothing about it.
    var bibliography: String?
    /// The document on screen, when there is one. A bar about a collection and a bar
    /// about one document are not the same bar: "4.2 MB here · 15.3 GB in the library" is
    /// the right sentence under a shelf and the wrong one under a page.
    var document: DocumentFacts?
    @State private var showingActivity = false
    private let regions: Regions = .shared
    private let library: LibraryStatus = .shared

    /// The plan being worked through, when one is on screen.
    var plan: PlanFacts?

    /// What the bar says while a plan is being reviewed.
    struct PlanFacts: Equatable {
        let total: Int
        let confirmed: Int
        let skipped: Int
        let trashed: Int
        let pending: Int
        /// Where the originals go when the plan is applied, or nil when they are replaced
        /// in place. Worth a permanent line: it is the difference between a rename you can
        /// take back and one you cannot.
        let backupFolder: String?
        let sources: Int
        let builtAt: Date?

        var decided: Int { total - pending }
        var fraction: Double { total > 0 ? Double(decided) / Double(total) : 0 }

        var progress: String {
            var parts: [String] = []
            if confirmed > 0 { parts.append("\(confirmed) confirmed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if trashed > 0 { parts.append("\(trashed) to trash") }
            parts.append("\(pending) to go")
            return parts.joined(separator: " \u{00B7} ")
        }

        var originals: String {
            guard let backupFolder else { return "Originals are replaced" }
            return "Originals move to \(backupFolder)/"
        }

        var built: String {
            guard let builtAt else { return "No plan built yet" }
            let source = "\(sources) source\(sources == 1 ? "" : "s")"
            return "Plan built \(ago(builtAt)) from \(source)"
        }

        /// "just now", "2 min ago", "3 hours ago". A plan is minutes old or it is stale;
        /// nothing in between needs a date.
        private func ago(_ date: Date, now: Date = Date()) -> String {
            let seconds = now.timeIntervalSince(date)
            switch seconds {
            case ..<60: return "just now"
            case ..<3600: return "\(Int(seconds / 60)) min ago"
            case ..<86_400: return "\(Int(seconds / 3600)) hour\(Int(seconds / 3600) == 1 ? "" : "s") ago"
            default: return "\(Int(seconds / 86_400)) day\(Int(seconds / 86_400) == 1 ? "" : "s") ago"
            }
        }
    }

    /// What the bar says about the one document being read.
    struct DocumentFacts: Equatable {
        let path: String
        let bytes: Int?
        let pages: Int
        let locked: Bool
        let highlights: Int
        let notes: Int

        var physical: String {
            var parts: [String] = []
            if let bytes {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                                       countStyle: .file))
            }
            if pages > 0 { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
            parts.append(locked ? "locked" : "unlocked")
            return parts.joined(separator: " · ")
        }

        var marks: String {
            "\(highlights) highlight\(highlights == 1 ? "" : "s") · "
                + "\(notes) note\(notes == 1 ? "" : "s")"
        }
    }

    var body: some View {
        if let document {
            readerBar(document)
        } else if let plan {
            planBar(plan)
        } else {
            collectionBar
        }
    }

    /// Working through a plan: how far along it is, what happens to the originals, and
    /// how old the plan on screen is.
    ///
    /// The collection's bar says how much the shelf weighs and how much the library
    /// holds, which are the wrong two facts to have in front of you while deciding four
    /// hundred filenames one at a time.
    private func planBar(_ plan: PlanFacts) -> some View {
        HStack(spacing: Space.step) {
            ProgressView(value: plan.fraction)
                .progressViewStyle(.linear)
                .frame(width: 110)
                .tip("\(plan.decided) of \(plan.total) decided")

            Text(plan.progress)
            separator
            Text(plan.originals)

            Spacer(minLength: Space.step)

            if runner.phase != .idle || activity.indexing || activity.absorbing {
                runningNow
                separator
            }

            ForEach(warnings, id: \.text) { warning in
                Text(warning.text).foregroundStyle(warning.colour)
                separator
            }

            if let spend {
                Text(spend)
                separator
            }

            Text(plan.built)
            separator
            Text("? for every shortcut")
        }
        .modifier(StatusBarChrome())
        .onChange(of: regions.focused) { _, region in
            if region == .status { showingActivity = true }
        }
    }

    /// Reading: what is open, how big it is, what is on it, and the two facts about the
    /// app itself that are true whatever is on screen.
    private func readerBar(_ document: DocumentFacts) -> some View {
        HStack(spacing: Space.step) {
            Text(shorten(document.path))
                .truncationMode(.middle)
                .tip(document.path)
            separator
            Text(document.physical)

            Spacer(minLength: Space.step)

            // Only while it is doing something. Idle, this is a button about the
            // collection, and the bar under a page is not the place for it.
            if runner.phase != .idle || activity.indexing || activity.absorbing {
                runningNow
                separator
            }

            Text(document.marks)
            separator

            if let label = library.label {
                Text(label)
                separator
            }

            watchingDot
        }
        .modifier(StatusBarChrome())
        .onChange(of: regions.focused) { _, region in
            if region == .status { showingActivity = true }
        }
    }

    private var collectionBar: some View {
        HStack(spacing: Space.step) {
            runningNow

            if let bibliography {
                separator
                Text(bibliography)
            } else if let counts = decisions {
                separator
                Text(counts)
            }

            planState

            Spacer(minLength: Space.step)

            if activity.showingCached {
                Label("From last time, rechecking the disk", systemImage: "clock.arrow.circlepath")
                separator
            }

            ForEach(warnings, id: \.text) { warning in
                Text(warning.text).foregroundStyle(warning.colour)
                separator
            }

            if let spend {
                Text(spend)
                separator
            }

            if let selection = selectionLabel {
                Text(selection)
                    .truncationMode(.middle)
                    .tip(selectedPath ?? "")
                separator
            }

            Text(sizeLabel)
            separator

            watchingDot
        }
        .modifier(StatusBarChrome())
        // Focusing the status bar opens what it is a summary of, which is the only useful
        // thing focus can mean for a bar of text.
        .onChange(of: regions.focused) { _, region in
            if region == .status { showingActivity = true }
        }
    }

    private var watchingDot: some View {
        HStack(spacing: Space.tight) {
            Circle()
                .fill(watching ? Color.green : unavailableSources > 0 ? Ink.amber : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(watchingLabel)
        }
    }

    /// A path said the way a person keeps it: under the home folder, from the home folder.
    private func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Whether what is on screen is a plan, an applied run, or a plan that no longer
    /// describes the settings it was built with.
    @ViewBuilder
    private var planState: some View {
        if runner.results.isEmpty {
            EmptyView()
        } else if !runner.lastRunWasDry {
            separator
            Label("Applied, files on disk have changed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Ink.green)
        } else if !planIsCurrent {
            separator
            Label("Settings changed, plan again", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Ink.amber)
        } else if runner.appliedCount > 0 {
            separator
            Text("\(runner.appliedCount) applied so far, the rest is still only planned")
                .foregroundStyle(Ink.green)
        }
    }

    /// What the watcher is doing, including the thing it last did — a file arriving while
    /// you are looking at something else is worth one line of acknowledgement.
    private var watchingLabel: String {
        if !watching {
            return unavailableSources > 0
                ? "\(unavailableSources) source\(unavailableSources == 1 ? "" : "s") unavailable"
                : "Not watching"
        }
        let taken = activity.lastAbsorbed
        guard taken > 0 else {
            let missing = unavailableSources > 0
                ? " · \(unavailableSources) unavailable"
                : ""
            return "Watching \(sources) source\(sources == 1 ? "" : "s")\(missing)"
        }
        return "Took in \(taken) new file\(taken == 1 ? "" : "s")"
    }

    private var separator: some View {
        Text("|").foregroundStyle(.quaternary)
    }

    /// What the app is doing, with a bar only while there is something to measure.
    @ViewBuilder
    private var runningNow: some View {
        switch runner.phase {
        case .scanning:
            HStack(spacing: Space.step) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text("Scanning — \(activity.found) PDF\(activity.found == 1 ? "" : "s") found")
            }
        case .processing:
            HStack(spacing: Space.step) {
                ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(activity.done) of \(activity.total)")
                    .monospacedDigit()
            }
        case .idle where activity.indexing:
            // Reading documents' text so a search can look inside them. The shelf is
            // usable throughout, so this is a line rather than an overlay, and it says
            // how to stop.
            HStack(spacing: Space.step) {
                ProgressView(value: Double(activity.indexed),
                             total: Double(max(activity.indexTotal, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("Indexing text \(activity.indexed) of \(activity.indexTotal)")
                    .monospacedDigit()
                Button("Stop") { runner.stopIndexing() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        case .idle where activity.absorbing:
            // The watcher taking in files it just noticed. Its own line until now, in a
            // second bar underneath this one.
            HStack(spacing: Space.step) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text(activity.total > 0
                     ? "Reading \(activity.done) of \(activity.total) new files"
                     : "Checking what changed")
            }
        case .idle:
            Button { showingActivity.toggle() } label: {
                HStack(spacing: Space.snug) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(idleLabel)
                }
            }
            .buttonStyle(.plain)
            .help("Everything that has happened, newest first")
            .popover(isPresented: $showingActivity, arrowEdge: .top) {
                ActivityLog(entries: activity.log)
            }
        }
    }

    /// The selected file, by path, with when it was last read. Middle-truncated by the
    /// view: the two ends of a path are the parts that identify it.
    private var selectionLabel: String? {
        guard let selectedPath else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = selectedPath.hasPrefix(home)
            ? "~" + selectedPath.dropFirst(home.count)
            : selectedPath
        guard let lastOpened else { return shown }
        return "\(shown) · \(openedLabel(lastOpened))"
    }

    /// How much the shelf and the library weigh. A person adding a four-terabyte drive is
    /// asking a size question, and the app knew both numbers and said neither.
    private var sizeLabel: String {
        let here = runner.results.reduce(0) { $0 + ($1.byteCount ?? 0) }
        let shown = ByteCountFormatter.string(fromByteCount: Int64(here), countStyle: .file)
        guard let totals = runner.libraryTotals, totals.bytes > here else {
            return "\(shown) here"
        }
        let whole = ByteCountFormatter.string(fromByteCount: Int64(totals.bytes), countStyle: .file)
        return "\(shown) here · \(whole) in the library"
    }

    private var idleLabel: String {
        guard !runner.results.isEmpty else {
            return sources == 0 ? "No sources yet" : "Nothing found in \(sources) source\(sources == 1 ? "" : "s")"
        }
        guard runner.lastRunWasDry else { return "Applied to \(runner.results.count) files" }
        return "\(runner.results.count) file\(runner.results.count == 1 ? "" : "s")"
    }

    /// Only while there is a plan to be part-way through. A row of zeroes is noise.
    private var decisions: String? {
        guard runner.lastRunWasDry, !runner.results.isEmpty, runner.reviewed > 0 else { return nil }
        var parts: [String] = []
        if runner.confirmedCount > 0 { parts.append("\(runner.confirmedCount) confirmed") }
        if runner.skippedCount > 0 { parts.append("\(runner.skippedCount) skipped") }
        if runner.deletedCount > 0 { parts.append("\(runner.deletedCount) to trash") }
        if runner.pendingCount > 0 { parts.append("\(runner.pendingCount) to go") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The two things worth colouring: files no password opened, and books you have twice.
    private var warnings: [(text: String, colour: Color)] {
        var out: [(String, Color)] = []
        let locked = runner.statusCounts.first { $0.0 == .locked }?.1 ?? 0
        if locked > 0 { out.append(("\(locked) locked", Ink.amber)) }
        if !runner.duplicates.isEmpty {
            out.append(("\(runner.duplicates.count) duplicate group\(runner.duplicates.count == 1 ? "" : "s")", Ink.purple))
        }
        // Files the indexer could not open. Said once, as a number: on a disk that has
        // stopped answering this is every file, and a list of names would be the whole
        // shelf written along the bottom of the window.
        if activity.indexFailures > 0 {
            out.append(("\(activity.indexFailures) could not be read", Ink.amber))
        }
        return out
    }
}
