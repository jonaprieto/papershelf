import SwiftUI
import AppKit
import PaperShelfCore

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
    ///
    /// Remembered when the adaptor makes it, not looked up. This was
    /// `NSApp.delegate as? AppDelegate`, and under `@NSApplicationDelegateAdaptor` the
    /// application's delegate is SwiftUI's own object, which forwards to this one, so the
    /// cast was nil in the running app every time. Nothing that reached for it worked:
    /// asking for the Library window from its menu item, the command palette or Open
    /// Website never set `wantsLibrary`, and the folder a paper opened from Finder should
    /// have lent the window was never lent.
    private(set) static weak var current: AppDelegate?

    override init() {
        super.init()
        AppDelegate.current = self
    }

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkForUpdates(manual: false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkForUpdates(manual: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.shared.record("terminate")
    }

    /// The dock icon with nothing on screen brings the library back. With a reader already
    /// open it does nothing, which is the point: opening a second paper used to activate the
    /// app, and activating it built the library window nobody asked for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, readers.isEmpty else { return false }
        wantsLibrary = true
        return true
    }

    /// Where a reader's own size and position are kept between launches.
    static let readerFrameName = "reader"

    func openReader(for url: URL) {
        let key = url.resolvingSymlinksInPath().path
        if let existing = readers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Sized to the display rather than to a constant. At a flat 900 by 1000 a reader
        // was taller than the 875 points a 13 inch laptop has, so AppKit trimmed it on
        // the way to the screen and every reader there opened at full screen height.
        let visible = NSScreen.main?.visibleFrame.size
            ?? CGSize(width: SplitLayout.readerIdealWidth, height: SplitLayout.readerIdealHeight)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SplitLayout.readerWindowSize(visible: visible)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = url.lastPathComponent
        window.representedURL = url
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReaderWindow(url: url))
        // The autosave name only turns saving on; reading the frame back is a separate
        // call, and without it a reader opened at the size above however the last one had
        // been left. center() ran unconditionally after it, which would have thrown away
        // a restored position in any case.
        window.setFrameAutosaveName(Self.readerFrameName)
        if !window.setFrameUsingName(Self.readerFrameName) { window.center() }

        let controller = NSWindowController(window: window)
        readers[key] = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readers[key] = nil }
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether this window is one opened for a file handed over by the machine, rather
    /// than a paper being read inside the library.
    func isReader(_ window: NSWindow) -> Bool {
        readers.values.contains { $0.window === window }
    }

    /// Whether a library window is on screen.
    ///
    /// Not `wantsLibrary`: that says whether anybody has asked for one this session, and
    /// it is still false on an ordinary launch where SwiftUI made the window itself.
    var showsLibrary: Bool {
        libraryWindows.contains(where: \.isVisible)
    }

    /// The library window, identified by the scene id SwiftUI puts on it. Matched loosely
    /// because that string is SwiftUI's to shape ("main", "SwiftUI.Window-main"), and the
    /// title is matched as a second chance for the same window.
    private var libraryWindows: [NSWindow] {
        NSApp.windows.filter { window in
            guard !isReader(window) else { return false }
            let identifier = window.identifier?.rawValue ?? ""
            return identifier.contains("main") || window.title == "PaperShelf"
        }
    }

    private func closeLibraryWindow() {
        for window in libraryWindows { window.close() }
    }
}
