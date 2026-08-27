import SwiftUI
import AppKit
import Quartz
import PDFHammerCore

/// A right-click menu for a file.
///
/// Finder's own contextual menu is not something another app can borrow: it is built
/// inside Finder and not exposed. What *is* reusable is everything behind it, so the
/// entries here call the same system machinery Finder does. Open With is the real list of
/// applications the system says can open the file, and Share is the system's own sharing
/// services, not a hand-written imitation.
struct FileContextMenu: View {
    let item: Item
    let confirm: () -> Void
    let identify: () -> Void
    let moveTo: () -> Void
    let trash: () -> Void
    let skip: () -> Void
    let convert: () -> Void
    /// This file's own tags, and every tag in use anywhere else, so adding one is a pick
    /// rather than a retype that can be misspelled. See `CatalogueTags` in Catalogue.swift.
    var tags: [String] = []
    var availableTags: [String] = []
    /// False only when the library itself could not be opened. A file not indexed yet is
    /// not this case: adding a tag indexes it on the spot (see `CatalogueTags.add`).
    var tagsAvailable = true
    var onAddTag: (String) -> Void = { _ in }
    var onRemoveTag: (String) -> Void = { _ in }
    var onNewTag: () -> Void = {}

    var body: some View {
        Button("Open") { NSWorkspace.shared.open(item.currentURL) }

        Menu("Open With") {
            ForEach(applications(), id: \.self) { app in
                Button(app.deletingPathExtension().lastPathComponent) {
                    NSWorkspace.shared.open([item.currentURL], withApplicationAt: app,
                                            configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        .disabled(applications().isEmpty)

        Button("Quick Look") { QuickLook.show(item.currentURL) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.currentURL]) }

        Divider()

        tagsMenu

        Divider()

        Button("Copy Name") { copy(item.sourceName) }
        Button("Copy Path") { copy(item.currentURL.path) }
        Button("Copy Suggested Name") { copy(item.destinationName) }

        Divider()

        Button("Convert to Markdown…") { convert() }

        Divider()

        Button("Confirm", action: confirm)
        Button("Ask AI for a Name", action: identify)
        Button("Move to…", action: moveTo)
        Button("Skip", action: skip)
        Button("Move to Trash", role: .destructive, action: trash)
    }

    /// What the file has (click one to remove it), what is already in use elsewhere
    /// (click one to add it), and a way to type a genuinely new one.
    @ViewBuilder
    private var tagsMenu: some View {
        Menu("Tags") {
            if !tagsAvailable {
                Button("Library Unavailable") {}.disabled(true)
            } else {
                if tags.isEmpty {
                    Button("No Tags Yet") {}.disabled(true)
                } else {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            onRemoveTag(tag)
                        } label: {
                            Label(tag, systemImage: "checkmark")
                        }
                    }
                    Divider()
                }
                let suggestions = availableTags.filter { !tags.contains($0) }
                if !suggestions.isEmpty {
                    ForEach(suggestions, id: \.self) { tag in
                        Button(tag) { onAddTag(tag) }
                    }
                    Divider()
                }
                Button("New Tag…", action: onNewTag)
            }
        }
    }

    /// Every application the system says can open this file, which is the same list
    /// Finder shows.
    private func applications() -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: item.currentURL)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The system Quick Look panel, driven by a single URL.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    private static let shared = QuickLook()
    private var url: URL?

    static func show(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
