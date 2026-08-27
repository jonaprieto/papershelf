import SwiftUI
import AppKit
import PDFHammerCore

/// The file's bibliography entry, beside the file.
///
/// The bibliography tab builds the whole shelf at once, which is the wrong shape when you
/// are working through one document at a time: the entry you want to check is the one for
/// the file in front of you, and the moment to fix it is while you are looking at it.
extension ReviewInspector {

    @ViewBuilder var bibtexPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = runner.bibByItem[item.key] {
                let missing = entry.missing
                if !missing.isEmpty {
                    Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                         text: "\(entry.type.rawValue) wants " + missing.joined(separator: ", ")
                               + ". LaTeX will complain.",
                         size: .caption)
                }

                TextEditor(text: $citationDraft)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

                HStack(spacing: 8) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(citationDraft + "\n", forType: .string)
                    }
                    .tip("Copy the entry as it stands", key: "B")

                    Button(citationStored ? "Stored" : "Store") { storeCitation() }
                        .disabled(citationStored || citationDraft.isEmpty)
                        .tip("Keep this entry with the document, so it survives a relaunch "
                             + "and is used instead of one guessed from the filename")

                    Button {
                        improve()
                    } label: {
                        if citationImproving {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Asking…")
                            }
                        } else {
                            Label("Improve with AI", systemImage: "sparkles")
                        }
                    }
                    .disabled(!aiReady || citationImproving)
                    .tip(aiReady
                         ? "Send this entry and the opening text, and take back a corrected one"
                         : "Needs an API key, in Settings")

                    Spacer()

                    if citationDraft != generatedCitation {
                        Button("Reset") {
                            citationDraft = generatedCitation
                            citationStored = false
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout)

                if let citationNote {
                    Text(citationNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No entry yet. The bibliography is built from the plan, so run a "
                     + "preview first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.key) { await loadCitation() }
    }

    /// Sends the entry and the document's opening text, and takes back a corrected one.
    ///
    /// The reply is read for an entry rather than trusted to be one, and a reply with no
    /// entry in it leaves what was there: a model's prose is not an improvement on a
    /// citation that at least compiles.
    private func improve() {
        guard !citationImproving, !citationDraft.isEmpty else { return }
        citationImproving = true
        citationNote = nil
        let current = citationDraft
        let filename = item.destinationName
        let text = excerpt ?? openingText(of: item.currentURL, passwords: passwords, pages: 3)

        Task {
            defer { citationImproving = false }
            do {
                let reply = try await improveCitation(
                    bibtexImproveInstruction,
                    bibtexImprovePrompt(entry: current, filename: filename, excerpt: text))
                guard let improved = extractBibtexEntry(from: reply) else {
                    citationNote = "The reply had no entry in it, so nothing was changed."
                    return
                }
                citationDraft = improved
                citationImprovedByAI = true
                citationStored = false
                citationNote = improved == current
                    ? "The model left it as it was."
                    : "Changed by the model. Check it before you keep it."
            } catch {
                citationNote = error.localizedDescription
            }
        }
    }

    /// The entry as the app would generate it, which is what Reset goes back to.
    var generatedCitation: String {
        guard let entry = runner.bibByItem[item.key] else { return "" }
        return bibtexBlock(entry)
    }

    private func loadCitation() async {
        citationNote = nil
        citationImproving = false
        runner.ensureBib()

        // A kept entry wins over a generated one: it is the answer someone already
        // decided on, and regenerating would quietly throw that away.
        if let library = Library.shared,
           let documentID = try? await library.document(atPath: item.currentURL
                                                            .resolvingSymlinksInPath().path)?.id,
           let stored = try? await library.bibtex(forDocument: documentID) {
            citationDraft = stored.entry
            citationStored = true
            citationNote = "Kept \(stored.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                + " from \(stored.origin)."
            return
        }
        citationDraft = generatedCitation
        citationStored = false
    }

    private func storeCitation() {
        let entry = citationDraft
        guard !entry.isEmpty, let library = Library.shared else {
            citationNote = "There is no library to keep it in."
            return
        }
        let path = item.currentURL.resolvingSymlinksInPath().path
        let origin = citationImprovedByAI ? "the model" : "you"
        Task {
            guard let documentID = try? await library.document(atPath: path)?.id else {
                citationNote = "This file is not in the library yet, so there is nothing to "
                    + "attach the entry to."
                return
            }
            do {
                try await library.storeBibtex(entry, forDocument: documentID, origin: origin)
                citationStored = true
                citationNote = "Kept with the document."
                runner.note(.edited, subject: item.relativePath, detail: "citation kept")
            } catch {
                citationNote = "Could not keep it: \(error.localizedDescription)"
            }
        }
    }
}
