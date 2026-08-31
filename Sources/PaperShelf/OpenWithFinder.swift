import SwiftUI
import AppKit

/// What happens when the machine hands the app a file.
///
/// Reader windows are AppKit windows the delegate owns rather than a SwiftUI scene, for a
/// plain reason: `application(_:open:)` can arrive before any scene exists, and the
/// environment's `openWindow` is reachable only from inside one. A `DocumentGroup` would
/// solve that and bring a document model, an autosave story and a save panel with it, none
/// of which a viewer for files it does not own has any use for.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running delegate, so the menu can say that a library window was asked for.
    static var current: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// Whether anybody has asked to see the library this session. Until they have, a
    /// library window is something SwiftUI made on its own: a `Window` scene is rebuilt
    /// whenever the app is activated with none on screen, and opening a second paper
    /// activates the app.
    var wantsLibrary = false
    /// One window per file, keyed by the path with symlinks resolved, so opening the same
    /// paper twice raises the window that already has it rather than making a second.
    private var readers: [String: NSWindowController] = [:]

    /// When this delegate was made, which SwiftUI does as the app starts. A file that
    /// arrives within a few seconds of that is the reason the app is running; one that
    /// arrives later is somebody double-clicking a second paper while the library is
    /// already open, and their library window is theirs to keep.
    ///
    /// Time rather than `applicationDidFinishLaunching`: the open event and the finish of
    /// launching race, and which arrives first is not something to build on.

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openReader(for: url) }
        guard !wantsLibrary else { return }
        // Twice, and the second one late. The window this closes is not always there yet:
        // the open event activates the app, and activation is what makes SwiftUI rebuild
        // the scene, which can land after this returns. Closing after the readers exist
        // also matters -- closing the last window of the app while it has nothing else on
        // screen is how it gets terminated out from under the file it was opening.
        closeLibraryWindow()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !wantsLibrary else { return }
            closeLibraryWindow()
        }
    }

    /// The dock icon with nothing on screen brings the library back. With a reader already
    /// open it does nothing, which is the point: opening a second paper used to activate the
    /// app, and activating it built the library window nobody asked for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, readers.isEmpty else { return false }
        wantsLibrary = true
        return true
    }

    func openReader(for url: URL) {
        let key = url.resolvingSymlinksInPath().path
        if let existing = readers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = url.lastPathComponent
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReaderWindow(url: url))
        window.setFrameAutosaveName("reader")
        window.center()

        let controller = NSWindowController(window: window)
        readers[key] = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readers[key] = nil }
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The library window, identified by the scene id SwiftUI puts on it. Matched loosely
    /// because that string is SwiftUI's to shape ("main", "SwiftUI.Window-main"), and the
    /// title is matched as a second chance for the same window.
    private func closeLibraryWindow() {
        for window in NSApp.windows where !readers.values.contains(where: { $0.window === window }) {
            let identifier = window.identifier?.rawValue ?? ""
            if identifier.contains("main") || window.title == "PaperShelf" {
                window.close()
            }
        }
    }
}
