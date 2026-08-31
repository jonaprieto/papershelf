import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperShelfCore

/// The activity log, in a popover from the status bar.
///
/// It was a rail tab, which meant reading what just happened cost the sidebar — the one
/// column showing you where you are. A log is read when something has gone wrong, beside
/// the progress that prompted the question, and it costs no horizontal room here.
struct ActivityLog: View {
    let entries: [LogEntry]
    @State private var saving = false

    private static let colours: [LogEntry.Kind: Color] = [
        .failed: Ink.red, .trashed: Ink.red, .moved: Ink.purple,
        .decrypted: Ink.green, .renamed: Ink.green, .applied: Ink.green,
    ]

    private func colour(_ kind: LogEntry.Kind) -> Color {
        if kind == .skipped { return .secondary }
        return Self.colours[kind] ?? Ink.blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(Face.headline)
                Spacer()
                Text("\(entries.count) recorded")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)

            Divider()

            if entries.isEmpty {
                Text("Nothing yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Space.margin)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Newest first: the last thing that happened is what you came to
                        // check. Two hundred is what a person scrolls; the rest is what
                        // Save is for.
                        ForEach(entries.reversed().prefix(200)) { entry in
                            VStack(alignment: .leading, spacing: Space.hair) {
                                HStack(spacing: Space.snug) {
                                    Text(entry.kind.rawValue)
                                        .font(Face.caption.weight(.semibold))
                                        .foregroundStyle(colour(entry.kind))
                                    Text(entry.at, style: .time)
                                        .font(Face.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Text(entry.subject)
                                    .font(Face.caption)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                if !entry.detail.isEmpty {
                                    Text(entry.detail)
                                        .font(Face.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.roomy)
                            .padding(.vertical, Space.tight)
                        }
                    }
                    .padding(.vertical, Space.tight)
                }
            }

            Divider()

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText(entries), forType: .string)
                }
                .disabled(entries.isEmpty)
                Spacer()
                Button("Save…") { saving = true }
                    .disabled(entries.isEmpty)
            }
            .padding(.horizontal, Space.roomy)
            .padding(.vertical, Space.step)
        }
        .frame(width: 420, height: 460)
        .fileExporter(isPresented: $saving,
                      document: TextDocument(text: logText(entries)),
                      contentType: .plainText,
                      defaultFilename: "papershelf-activity") { _ in }
    }
}
