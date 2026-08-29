import SwiftUI
import PDFHammerCore

/// The strip along the bottom of the window.
///
/// The app had nowhere to put anything transient, so progress, counts and the state label
/// lived in a second row of the results bar that appeared and disappeared — which meant
/// the toolbar changed shape while work was running and the content below it jumped. All
/// of that lives here now, in a bar that is always exactly one line tall.
struct StatusBar: View {
    @ObservedObject var runner: Runner
    /// Observed on its own: these are the numbers that move several times a second, and
    /// this bar is one of the two places that show them.
    @ObservedObject var activity: Activity
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
    /// What the library holds. A fact about the whole collection rather than about this
    /// run, and the last thing before the watcher's own state.
    let library: String?
    @State private var showingActivity = false
    @ObservedObject private var regions: Regions = .shared

    var body: some View {
        HStack(spacing: 10) {
            runningNow

            if let counts = decisions {
                separator
                Text(counts)
            }

            plan

            Spacer(minLength: 8)

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

            if let library {
                Text(library)
                separator
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(watching ? Color.green : unavailableSources > 0 ? Ink.amber : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(watchingLabel)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: Metric.statusBar)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .region(.status)
        // Focusing the status bar opens what it is a summary of, which is the only useful
        // thing focus can mean for a bar of text.
        .onChange(of: regions.focused) { _, region in
            if region == .status { showingActivity = true }
        }
    }

    /// Whether what is on screen is a plan, an applied run, or a plan that no longer
    /// describes the settings it was built with.
    @ViewBuilder
    private var plan: some View {
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
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text("Scanning — \(activity.found) PDF\(activity.found == 1 ? "" : "s") found")
            }
        case .processing:
            HStack(spacing: 7) {
                ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(activity.done) of \(activity.total)")
                    .monospacedDigit()
            }
        case .idle where activity.absorbing:
            // The watcher taking in files it just noticed. Its own line until now, in a
            // second bar underneath this one.
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text(activity.total > 0
                     ? "Reading \(activity.done) of \(activity.total) new files"
                     : "Checking what changed")
            }
        case .idle:
            Button { showingActivity.toggle() } label: {
                HStack(spacing: 6) {
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
        return out
    }
}
