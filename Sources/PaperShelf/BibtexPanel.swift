import SwiftUI
import AppKit
import PaperShelfCore

/// The file's bibliography entry, beside the file.
///
/// The bibliography tab builds the whole shelf at once, which is the wrong shape when you
/// are working through one document at a time: the entry you want to check is the one for
/// the file in front of you, and the moment to fix it is while you are looking at it.
extension ReviewInspector {

    @ViewBuilder var bibtexPanel: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            if runner.bibLoading {
                ProgressView("Preparing citation…")
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            } else if runner.bibByItem[item.key] != nil {
                // Judged from the text on the screen, not from the entry the app would
                // have generated: the moment anyone edits it or keeps a fetched one, the
                // generated entry stops describing what is actually there. Recomputed on
                // every keystroke, since citationDraft is state this view reads.
                warning

                // Sized to the entry rather than given a fixed height with its own
                // scroller. The pane it sits in already scrolls, and a scroll view inside
                // a scroll view clipped the last lines of a normal entry: the closing
                // brace and the DOI were simply not there. The editor measures itself and
                // says how tall it is (see `BibtexEditor.report`).
                BibtexEditor(text: $citationDraft) { citationHeight = $0 }
                    .frame(height: max(citationHeight, 40))
                    .padding(Space.tight)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

                HStack(spacing: Space.step) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(citationDraft + "\n", forType: .string)
                    }
                    .tip("Copy the entry as it stands", key: "B")

                    // Prominent once the model has changed it: an answer nobody kept is
                    // an answer that is gone at the next file, and this is the step that
                    // decides whether the work counted.
                    Group {
                        if needsKeeping {
                            Button("Store") { storeCitation() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(citationStored ? "Stored" : "Store") { storeCitation() }
                                .disabled(citationStored || citationDraft.isEmpty)
                        }
                    }
                    .tip("Keep this entry with the document, so it survives a relaunch "
                         + "and is used instead of one guessed from the filename")

                    Button {
                        confirmingImprove = true
                    } label: {
                        if citationImproving {
                            HStack(spacing: Space.tight) {
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

                    // The bibliography draws no page of its own, so checking an entry
                    // against the title page it came from meant leaving the view that
                    // asked the question. This is the way there and back.
                    if !showsPage {
                        Button { read() } label: {
                            Label("Show the page", systemImage: "doc.text.image")
                        }
                        .buttonStyle(.link)
                        .tip("Open this document beside the entry")
                    }

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
                .font(Face.control)

                if let citationNote {
                    Text(citationNote)
                        .font(Face.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No entry yet. The bibliography is built from the plan, so run a "
                     + "plan first.")
                    .font(Face.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.key) { await loadCitation() }
        // Asked first, like every other billed call in the app. It was the one that spent
        // money on a click, and the panel is where a person is going through entries one
        // at a time, which is exactly where an accidental click is easiest.
        .confirmationDialog("Improve this entry with AI?", isPresented: $confirmingImprove,
                            titleVisibility: .visible) {
            Button("Ask") { improve() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One billed request, sending this entry and the document's opening pages "
                 + "to \(URL(string: prefs.aiBaseURL)?.host ?? prefs.aiBaseURL). A model can be "
                 + "confidently wrong: what comes back is yours to check, and it is not "
                 + "kept until you press Store.")
        }
    }

    /// True while the entry on screen is worth keeping and has not been kept: the model
    /// changed it, or you did.
    var needsKeeping: Bool {
        !citationStored && !citationDraft.isEmpty && citationDraft != generatedCitation
    }


    /// What is wrong with the entry as it currently reads, if anything.
    @ViewBuilder private var warning: some View {
        if citationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if let gaps = bibtexGaps(in: citationDraft, standard: prefs.bibStandard) {
            if !gaps.isEmpty {
                Note(icon: "exclamationmark.triangle.fill", tint: .orange,
                     text: "\(parseBibtexEntry(citationDraft)?.rawType ?? "this entry") wants "
                           + gaps.joined(separator: ", ") + ". \(prefs.bibStandard.label) will complain.",
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
        await runner.ensureBibReady()

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
            // A file the library has not met yet is recorded on the way, the way filing
            // one into a project does. It used to be a dead end: the entry was written,
            // Store said the document did not exist, and the work was gone at the next
            // file with nothing the person could do about it from here.
            var documentID = try? await library.document(atPath: path)?.id
            if documentID == nil {
                documentID = try? await library.indexDocuments(
                    [indexInput(for: URL(fileURLWithPath: path))]).first?.id
            }
            guard let documentID else {
                guard asked == item.key else { return }
                citationNote = "Could not record this file, so there is nothing to attach "
                    + "the entry to."
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
