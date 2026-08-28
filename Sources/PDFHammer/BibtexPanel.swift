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
            if runner.bibByItem[item.key] != nil {
                // Judged from the text on the screen, not from the entry the app would
                // have generated: the moment anyone edits it or keeps a fetched one, the
                // generated entry stops describing what is actually there. Recomputed on
                // every keystroke, since citationDraft is state this view reads.
                warning

                // Sized to the entry rather than given a fixed height with its own
                // scroller. The pane it sits in already scrolls, and a scroll view inside
                // a scroll view clipped the last lines of a normal entry: the closing
                // brace and the DOI were simply not there.
                //
                // The height comes from a copy of the same text laid out with the same
                // font and insets, so it accounts for wrapping, which counting lines
                // would not.
                ZStack(alignment: .topLeading) {
                    Text(citationDraft.isEmpty ? " " : citationDraft)
                        .font(entryFont)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                    TextEditor(text: $citationDraft)
                        .font(entryFont)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .padding(.horizontal, 1)
                        .padding(.vertical, 3)
                }
                .padding(4)
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
                            // Back to the generated entry, which the model did not write:
                            // keeping the flag would record it as the model's work.
                            citationImprovedByAI = false
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
                     + "plan first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.key) { await loadCitation() }
    }

    private var entryFont: Font { .system(.caption, design: .monospaced) }

    /// What is wrong with the entry as it currently reads, if anything.
    @ViewBuilder private var warning: some View {
        if citationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if let gaps = bibtexGaps(in: citationDraft, standard: bibStandard) {
            if !gaps.isEmpty {
                Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                     text: "\(parseBibtexEntry(citationDraft)?.rawType ?? "this entry") wants "
                           + gaps.joined(separator: ", ") + ". \(bibStandard.label) will complain.",
                     size: .caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                 text: "This does not parse as a BibTeX entry.", size: .caption)
        }
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
        // A slow reply must not land on whatever file is on screen by the time it arrives.
        let asked = item.key

        Task {
            defer { if asked == item.key { citationImproving = false } }
            do {
                let reply = try await improveCitation(
                    bibtexImproveInstruction,
                    bibtexImprovePrompt(entry: current, filename: filename, excerpt: text))
                guard asked == item.key else { return }
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
                guard asked == item.key else { return }
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
        // A new file starts with no history, or the last file's improvement would be
        // recorded as the provenance of this one's entry.
        citationImprovedByAI = false
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
        let asked = item.key
        Task {
            guard let documentID = try? await library.document(atPath: path)?.id else {
                guard asked == item.key else { return }
                citationNote = "This file is not in the library yet, so there is nothing to "
                    + "attach the entry to."
                return
            }
            do {
                try await library.storeBibtex(entry, forDocument: documentID, origin: origin)
                // The entry belongs to that document whether or not it is still on screen,
                // so it is kept either way; only what the panel says is conditional.
                let places = (try? await library.locations(forDocument: documentID))?.map(\.path) ?? []
                KeptBibtex.shared.remember(entry, at: places + [path, asked])
                runner.note(.edited, subject: item.relativePath, detail: "citation kept")
                guard asked == item.key else { return }
                citationStored = true
                citationNote = "Kept with the document."
            } catch {
                guard asked == item.key else { return }
                citationNote = "Could not keep it: \(error.localizedDescription)"
            }
        }
    }
}
