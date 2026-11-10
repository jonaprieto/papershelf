import SwiftUI
import AppKit
import PaperShelfCore

/// The first screen anybody sees, and until now an empty list.
///
/// It has a few things to say and no room for a tour: where the books come from, that
/// nothing on disk moves until you have looked at what would happen, what the reader and
/// search do that a viewer does not, and that an assistant can read the library without
/// anything leaving the machine. That last one gets a way in, because the setup lives in
/// Settings and nothing else on a new shelf points there.
struct FirstRun: View {
    let chooseFiles: () -> Void
    private let prefs = Prefs.shared

    var body: some View {
        VStack(spacing: Space.margin) {
            VStack(spacing: Space.step) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                Text("Read, mark and cite your papers")
                    .font(Face.title2)
                Text("Point PaperShelf at the folders your PDFs already live in. It reads "
                     + "them where they are; nothing moves until you say so.")
                    .font(Face.control)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            VStack(alignment: .leading, spacing: Space.roomy) {
                point("text.magnifyingglass", "Search every page",
                      "Index text for search makes every paper's words findable, so a phrase "
                      + "you half remember finds its page. Convert to Markdown reads a scan "
                      + "with the OCR built into macOS.")
                point("highlighter", "Highlights that mean something",
                      "Five highlighters for definitions, evidence, doubts and follow-ups, "
                      + "with notes beside the passage. H, J, K and L scroll the page.")
                point("textformat.abc", "Names you can trust",
                      "Review suggested names before anything changes. Nothing is renamed "
                      + "until you apply it, and Trash is always recoverable.")
                point("sparkles", "Ask your library",
                      "Claude Code, Codex or ChatGPT can search the shelf through the server "
                      + "inside the app and answer with the passage and the page. It runs "
                      + "here; nothing leaves the machine.")
                if prefs.aiEnabled {
                    Button("Connect an assistant…") {
                        prefs.settingsPane = .integrations
                        PaletteSettings.openSettingsWindow()
                    }
                    .buttonStyle(.link)
                    .font(Face.caption)
                    .padding(.leading, 22 + Space.roomy)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            VStack(spacing: Space.snug) {
                Button("Add a folder or PDF…", action: chooseFiles)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("or drop folders and PDFs anywhere in this window")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                // The keys a new reader needs before anything else, said once here
                // rather than left for the menus to be found.
                Text("\(key(.openFile, or: "File > Open")) reads a single PDF on its own. "
                     + "\(key(.palette, or: "View > Command Palette")) finds a paper or any "
                     + "command, and Help > Keyboard Shortcuts lists the rest.")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.bay)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole pane is the target, not just the button.
        .contentShape(Rectangle())
        .onTapGesture(perform: chooseFiles)
    }

    private func key(_ command: Command, or menu: String) -> String {
        Keymap.shared.shortcut(for: command)?.display ?? menu
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Space.roomy) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title).font(Face.control.weight(.semibold))
                Text(body)
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
