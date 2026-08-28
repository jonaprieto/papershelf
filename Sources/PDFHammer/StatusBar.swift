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
    let watching: Bool
    let sources: Int
    /// Already formatted by the caller: money carries its currency and is never coerced
    /// into a Double on the way to a label.
    let spend: String?
    let showActivity: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            activity

            if let counts = decisions {
                separator
                Text(counts)
            }

            Spacer(minLength: 8)

            ForEach(warnings, id: \.text) { warning in
                Text(warning.text).foregroundStyle(warning.colour)
                separator
            }

            if let spend {
                Text(spend)
                separator
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(watching ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(watching
                     ? "Watching \(sources) source\(sources == 1 ? "" : "s")"
                     : "Not watching")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: Metric.statusBar)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var separator: some View {
        Text("|").foregroundStyle(.quaternary)
    }

    /// What the app is doing, with a bar only while there is something to measure.
    @ViewBuilder
    private var activity: some View {
        switch runner.phase {
        case .scanning:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                Text("Scanning — \(runner.found) PDF\(runner.found == 1 ? "" : "s") found")
            }
        case .processing:
            HStack(spacing: 7) {
                ProgressView(value: Double(runner.done), total: Double(max(runner.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(runner.done) of \(runner.total)")
                    .monospacedDigit()
            }
        case .idle:
            Button(action: showActivity) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(idleLabel)
                }
            }
            .buttonStyle(.plain)
            .help("Everything that has happened, newest first")
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
