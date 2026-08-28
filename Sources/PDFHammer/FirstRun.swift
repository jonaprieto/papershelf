import SwiftUI
import AppKit
import PDFHammerCore

/// The first screen anybody sees, and until now an empty list.
///
/// It has three things to say and no room for a tour: where the books come from, that
/// nothing on disk moves until you have looked at what would happen, and that the library
/// is readable by an assistant without anything leaving the machine. Everything else can
/// wait until there is a shelf to talk about.
struct FirstRun: View {
    let chooseFiles: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                Text("A shelf for the papers you actually read")
                    .font(.title2.weight(.semibold))
                Text("Point it at the folders your PDFs are already in. Nothing is copied "
                     + "anywhere, and nothing is moved until you say so.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            VStack(alignment: .leading, spacing: 14) {
                point("folder", "Add a source",
                      "A folder, or a single PDF. Sources are kept as a set of "
                      + "non-overlapping roots, so picking a parent absorbs what is inside it.")
                point("eye", "Look before anything happens",
                      "Plan works out every new name and touches nothing. You confirm file "
                      + "by file, or all at once, and originals are kept unless you turn "
                      + "that off. Delete always means the Trash.")
                point("puzzlepiece.extension", "Readable by your assistant",
                      "An MCP server ships inside the app, so Claude Code or Codex can "
                      + "search and read your library. It runs here; nothing leaves the "
                      + "machine. Settings › Integrations has the one line to paste.")
            }
            .frame(maxWidth: 520, alignment: .leading)

            VStack(spacing: 6) {
                Button("Choose Files or Folders…", action: chooseFiles)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("or drop them anywhere in this window")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole pane is the target, not just the button.
        .contentShape(Rectangle())
        .onTapGesture(perform: chooseFiles)
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
