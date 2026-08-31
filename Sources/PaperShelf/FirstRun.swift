import SwiftUI
import AppKit
import PaperShelfCore

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
                Text("A calm home for your PDFs")
                    .font(Face.title2)
                Text("Keep papers named, searchable, and annotated. Point PaperShelf at the "
                     + "folders your PDFs already live in; nothing moves until you say so.")
                    .font(Face.control)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            VStack(alignment: .leading, spacing: 14) {
                point("books.vertical.fill", "One home for every paper",
                      "Browse the folders you already use, or add one PDF. Sources stay "
                      + "separate, searchable, and easy to revisit.")
                point("textformat.abc", "Names you can trust",
                      "Review suggested names before anything changes. Originals stay safe "
                      + "by default, and Trash is always recoverable.")
                point("highlighter", "Highlights that mean something",
                      "Use a small personal palette for definitions, evidence, questions, "
                      + "and follow-ups, then attach notes to the passage.")
                point("sparkles", "AI when it helps",
                      "An MCP server ships inside the app, so Claude Code or Codex can "
                      + "search and read your library. It runs here; nothing leaves the "
                      + "machine. Turn on AI only when you need it.")
            }
            .frame(maxWidth: 520, alignment: .leading)

            VStack(spacing: 6) {
                Button("Add a folder or PDF…", action: chooseFiles)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("or drop folders and PDFs anywhere in this window")
                    .font(Face.caption)
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
                Text(title).font(Face.control.weight(.semibold))
                Text(body)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
