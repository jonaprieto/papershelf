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
        // Cleared once the library is really gone. SwiftUI keeps a closed `Window` scene's
        // view and does not always say it disappeared, which left a launch's library looking
        // as if it had been on screen all along when the next file arrived. Nor is a close
        // notice proof: one arrives for the library just before a file does, with the
        // window still on screen after it, so it is checked a moment later.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      self.libraryWindows.contains(where: { $0 === window }) else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if !self.showsLibrary { self.libraryAppearedAt = nil }
                }
            }
        }
    }

    /// Whether anybody has asked to see the library this session. Until they have, a
    /// library window is something SwiftUI made on its own: a `Window` scene is rebuilt
    /// whenever the app is activated with none on screen, and opening a second paper
    /// activates the app.
    var wantsLibrary = false
    /// One window per file, keyed by the path with symlinks resolved, so opening the same
    /// paper twice raises the window that already has it rather than making a second.
    private var readers: [String: NSWindowController] = [:]

    /// When the library window last came on screen, or nil while there is none. Set by the
    /// window itself.
    ///
    /// A library that was already on screen when a file arrives is somebody's, and stays.
    /// One that came up with the file is SwiftUI answering the activation the open caused,
    /// and goes. How long it has been there is what tells them apart: the open event and
    /// the finish of launching race, and which arrives first is not something to build on.
    /// This used to be described here with nothing behind it, so a paper double-clicked
    /// while an ordinary launch's library was on screen closed that library.
    var libraryAppearedAt: Date?

    /// Whether the only windows anybody asked for are readers. The library window SwiftUI
    /// makes anyway should then do none of its own work: scanning sources, watching
    /// folders and reopening tabs, for a window that is closed again a moment later.
    var libraryUnwanted: Bool { !wantsLibrary && !readers.isEmpty }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !wantsLibrary, let appeared = libraryAppearedAt, Date().timeIntervalSince(appeared) > 2 {
            wantsLibrary = true
        }
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
        libraryAppearedAt = nil
        for window in libraryWindows { window.close() }
    }
}
