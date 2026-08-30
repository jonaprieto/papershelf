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
                Text("Activity").font(.headline)
                Spacer()
                Text("\(entries.count) recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if entries.isEmpty {
                Text("Nothing yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Newest first: the last thing that happened is what you came to
                        // check. Two hundred is what a person scrolls; the rest is what
                        // Save is for.
                        ForEach(entries.reversed().prefix(200)) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(entry.kind.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(colour(entry.kind))
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 420, height: 460)
        .fileExporter(isPresented: $saving,
                      document: TextDocument(text: logText(entries)),
                      contentType: .plainText,
                      defaultFilename: "papershelf-activity") { _ in }
    }
}
