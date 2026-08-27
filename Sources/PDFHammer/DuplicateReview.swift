import SwiftUI
import AppKit
import PDFHammerCore

// The reviewers' objection to design around: a window that only marks files for deletion and
// then closes leaves someone believing they reclaimed space when nothing has actually
// happened yet -- exactly what the existing catalogue's trash button already does today,
// queuing a decision for a later batch Apply. `trashNow` below is not that. It is wired, by
// whoever calls `DuplicateReviewWindow.present`, to mark the file for deletion AND carry that
// out immediately (`Runner.markForDeletion` followed by `Runner.applyNow`, both of which
// already exist and already do exactly this for a single file today, see App.swift). The
// button reads "Trash now", not "Trash" or "Keep", because that is what it actually does the
// instant it is clicked, before the window closes.
//
// Whoever wires `trashNow` to `applyNow` MUST also call the shared `DuplicateIndex.remove(_:)`
// for the trashed file's key right after (see critique.md's "DuplicateIndex goes stale on
// Runner.applyNow" objection, about this exact index -- this button is a second, more direct
// way to hit the same staleness, since it calls `applyNow` itself). Without that, the index
// keeps a record of a file that this button just moved to the Trash, and a later arrival at
// the same size can still be matched against a digest that no longer corresponds to anything
// on disk.

/// Everything needed to choose, for one detected group, side by side: name, folder, size,
/// pages, modified date, and which copy this file's own ranking thinks is worth keeping.
/// Decoupled from `Runner`/`Covers` on purpose -- this file does not own either of those, so
/// every action a button here takes is a closure supplied by whoever presents the window.
struct DuplicateReviewView: View {
    let group: DuplicateGroup
    let thumbnail: (Item) -> NSImage?
    /// Trashes one file right now, not "marks it for later". See the file-level note.
    let trashNow: (Item) -> Void
    /// "Keep both, don't ask again" for the whole group: every file here, permanently.
    let keepBoth: () -> Void
    let onFinished: () -> Void

    @State private var actedOn: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline)
                .font(.headline)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(group.items) { item in
                        fileColumn(item)
                    }
                }
                .padding(.bottom, 4)
            }
            Divider()
            HStack {
                Button("Keep both, don't ask again") {
                    keepBoth()
                    onFinished()
                }
                .disabled(!actedOn.isEmpty)
                Spacer()
                Button("Ask me later") { onFinished() }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }

    private var headline: String {
        switch group.kind {
        case .identical: return "These look like the same file"
        case .sameText: return "These open with the same text"
        case .likely: return "These share a name"
        }
    }

    @ViewBuilder
    private func fileColumn(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = thumbnail(item) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: 200, height: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 200, height: 240)
            }
            Text(item.sourceName).font(.subheadline.bold()).lineLimit(2)
            Text(item.relativePath).font(.caption).foregroundStyle(.secondary)
            LabeledContent("Size", value: formattedSize(item.byteCount))
            LabeledContent("Pages", value: item.pageCount.map(String.init) ?? "unknown")
            if let modified = item.modifiedDate {
                LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
            }
            if item.key == group.keeper.key {
                Label("Looks like the better copy", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button(group.items.count == 2 ? "Keep this, trash now" : "Keep this, trash the rest now") {
                let others = group.items.filter { $0.key != item.key }
                for other in others { trashNow(other) }
                actedOn.formUnion(group.items.map(\.key))
                onFinished()
            }
            .disabled(!actedOn.isEmpty)
        }
        .frame(width: 200, alignment: .leading)
        .opacity(actedOn.isEmpty || actedOn.contains(item.key) ? 1 : 0.4)
    }

    private func formattedSize(_ bytes: Int?) -> String {
        guard let bytes else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A plain `NSWindow` over `DuplicateReviewView`, one per group, tracked by `DuplicateGroup.id`
/// so the same duplicate never opens a second window while the first is still up.
///
/// There is no SwiftUI `Window` scene for this because adding one means hoisting `Runner` and
/// `Covers` out of the view that owns them today (`@StateObject`, inside `ContentView` in
/// App.swift) up to the app struct -- a structural change to a file this piece does not own
/// this round, for both of the shared objects the window would need. A plain `NSWindow`
/// hosting the same SwiftUI view needs neither: it is opened straight from wherever the
/// watcher detects the duplicate, with everything it needs passed in as closures.
@MainActor
enum DuplicateReviewWindow {
    private static var open: [String: NSWindow] = [:]
    /// `NSWindow.delegate` is unowned, so the delegate object needs a strong owner somewhere
    /// else for as long as its window might still close -- this is that owner, keyed the same
    /// way `open` is so both entries are dropped together.
    private static var closers: [String: WindowCloseObserver] = [:]

    static func present(
        _ group: DuplicateGroup,
        thumbnail: @escaping (Item) -> NSImage?,
        trashNow: @escaping (Item) -> Void,
        keepBoth: @escaping () -> Void
    ) {
        if let existing = open[group.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Possible duplicate"
        window.isReleasedWhenClosed = false
        // The in-view buttons already route their own dismissal through `close(_:)` below,
        // but the window's own titlebar close control bypasses that entirely and calls
        // `NSWindow.close()` directly -- without this delegate, that path would leave a
        // closed-but-retained window (`isReleasedWhenClosed` is false on purpose, precisely
        // so a still-relevant duplicate can be re-shown by id) sitting in `open` forever,
        // both leaking it and making a later arrival of the same duplicate try to reactivate
        // a window nobody is meant to see again instead of presenting a fresh one.
        let closer = WindowCloseObserver(id: group.id)
        window.delegate = closer
        closers[group.id] = closer
        open[group.id] = window

        let view = DuplicateReviewView(
            group: group,
            thumbnail: thumbnail,
            trashNow: trashNow,
            keepBoth: keepBoth,
            onFinished: { close(group.id) }
        )
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func close(_ id: String) {
        open[id]?.close()
        forget(id)
    }

    fileprivate static func forget(_ id: String) {
        open[id] = nil
        closers[id] = nil
    }
}

/// See the comment where this is installed as a window's delegate: its only job is telling
/// `DuplicateReviewWindow` to drop its bookkeeping when a window closes by any path, not just
/// the ones this file's own buttons take.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    let id: String
    init(id: String) { self.id = id }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in DuplicateReviewWindow.forget(id) }
    }
}
