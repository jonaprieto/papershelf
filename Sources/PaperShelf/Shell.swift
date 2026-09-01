import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PaperShelfCore

/// Window chrome the menu bar needs to reach. The split view draws its own sidebar
/// button, so the menu supplies only the shortcut.
@MainActor
@Observable
final class Chrome {
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// Set by the window so the menu can reach the runner without owning it.
    var undo: () -> Void = {}
    var canUndo = false
    /// Window state the menu reaches through here, held in `Prefs` so it survives a
    /// launch and so the panes that draw it are invalidated when the menu changes it.
    ///
    /// These were `@AppStorage` on this object, which is not a view: the wrapper wrote
    /// the key but nothing on `Chrome` published the change, and the panes only redrew
    /// because they each held a second `@AppStorage` on the same key and `UserDefaults`
    /// told them separately.
    var reading: Bool {
        get { Prefs.shared.readingMode }
        set { Prefs.shared.readingMode = newValue }
    }
    var contentsShown: Bool {
        get { Prefs.shared.contentsShown }
        set { Prefs.shared.contentsShown = newValue }
    }
    var inspectorCollapsed: Bool {
        get { Prefs.shared.inspectorCollapsed }
        set { Prefs.shared.inspectorCollapsed = newValue }
    }
    var inspectorPanel: InspectorPanel {
        get { Prefs.shared.inspectorPanel }
        set { Prefs.shared.inspectorPanel = newValue }
    }

    /// Showing the notes means opening the inspector on its Notes tab. They were a column
    /// of their own with their own switch; now there is one inspector and ⌘⇧N says which
    /// of its tabs to be on, which is also why it can no longer be "shown" while the
    /// inspector is shut.
    func showNotes() {
        inspectorPanel = .notes
        inspectorCollapsed = false
    }

    var notesShown: Bool { !inspectorCollapsed && inspectorPanel == .notes }

    /// Reading mode gives the page the room the browser was using. It says nothing about
    /// the inspector.
    ///
    /// The panel was held shut by the mode as well as by its own switch, which is why the
    /// inspector button, ⌥⌘I and ⌘⇧N all appeared dead while reading: they flipped a
    /// value nothing was reading (see `ReviewInspector.showsPanel`). One switch decides
    /// the panel, and only the controls named after it touch that switch.
    func setReading(_ on: Bool) {
        reading = on
    }

    func toggleReading() { setReading(!reading) }

    /// Not animated, and neither are the notes and contents rails.
    ///
    /// Every one of these changes the width of the pane the PDF view sits in, and the view
    /// refits the page to its new width on each layout pass, re-rendering what is on screen
    /// each time. Animating the change turned one re-render into one per frame for the
    /// length of the animation, which is why opening or closing a rail felt slow on a long
    /// document. They snap now, and the panel is there before the click is over.
    func toggleSidebar() {
        // Not animated: see `Chrome.toggleSidebar`'s note.
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }
}

@main
struct PaperShelfApp: App {
    @State private var chrome = Chrome()
    @Environment(\.openWindow) private var openWindow
    // Finder's files arrive here, and the reader windows they open are the delegate's.
    // See `AppDelegate` for why they are not a scene.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private func openAbout() { openWindow(id: AboutWindow.windowID) }

    var body: some Scene {
        Window("PaperShelf", id: "main") {
            ContentView(chrome: chrome)
        }
        .commands {
            // The stock panel says a name, a version and a line of copyright. What this
            // app is, what you may do with it and what else is involved take a window.
            CommandGroup(replacing: .appInfo) {
                Button("About PaperShelf") { openAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: chrome.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!chrome.canUndo)
            }
            CommandGroup(after: .sidebar) {
                Button(chrome.reading ? "Leave Reading Mode" : "Reading Mode",
                       action: chrome.toggleReading)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(chrome.notesShown ? "Hide Notes" : "Show Notes") {
                    if chrome.notesShown { chrome.inspectorCollapsed = true } else { chrome.showNotes() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(chrome.inspectorCollapsed ? "Show Inspector" : "Hide Inspector") {
                    chrome.inspectorCollapsed.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Button(chrome.contentsShown ? "Hide Contents" : "Show Contents") {
                    chrome.contentsShown.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Toggle Sidebar", action: chrome.toggleSidebar)
                    .keyboardShortcut("b", modifiers: .command)
                Divider()
                // Reading a file opened from Finder no longer builds a library window, so
                // there has to be a way to ask for one.
                Button("Library") {
                    AppDelegate.current?.wantsLibrary = true
                    openWindow(id: "main")
                }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        Window("About PaperShelf", id: AboutWindow.windowID) {
            AboutWindow()
        }
        .windowResizability(.contentSize)

        // Settings are a window again. ⌘, is wired to this scene by the platform, which
        // is also what puts the item in the app menu where people look for it.
        Settings {
            SettingsWindowView()
        }
    }
}

// MARK: - Covers

/// Renders and caches first-page thumbnails. Nothing is drawn until a card asks for it,
/// so a shelf of thousands costs only what is on screen.
@MainActor
@Observable
final class Covers {
    private let cache = NSCache<NSString, NSImage>()
    /// Cards awaiting a render, by key, so several asking for the same file share one.
    private var waiting: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    /// Files no cover could be made from: a PDF this build cannot open, or a disk that
    /// stops serving its own bytes. Remembered because a shelf of fourteen thousand of
    /// them would otherwise re-render every one of them on every scroll, four at a time,
    /// against the disk that is already failing. Cleared with the cache.
    private var unrenderable: Set<String> = []
    /// Bumped only when the whole cache is emptied. A single thumbnail landing used to
    /// bump a counter every card read, so one render redrew the entire visible grid;
    /// now each card awaits its own cover and redraws alone.
    private(set) var generation = 0

    /// Four at a time: enough to fill a scroll, few enough to leave the UI responsive.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() { cache.countLimit = 400 }

    /// The cover if one is already rendered. Synchronous and cheap, so a card that has
    /// its cover draws it on the first pass with no flicker.
    func cached(_ item: Item) -> NSImage? {
        cache.object(forKey: item.key as NSString)
    }

    /// This one file's cover, awaited by the card that wants it.
    ///
    /// Several cards asking for the same file share a single render, and a card scrolled
    /// out of the grid simply stops awaiting. The queue is still four wide and the cache
    /// still holds four hundred, both of which were measured; what changed is who gets
    /// told when a render lands.
    /// Whether this file has already been tried and could not be drawn, so a card can say
    /// that rather than showing the placeholder a card still waiting shows.
    func couldNotRender(_ item: Item) -> Bool { unrenderable.contains(item.key) }

    func cover(for item: Item, passwords: [String], height: CGFloat) async -> NSImage? {
        if let hit = cache.object(forKey: item.key as NSString) { return hit }
        let key = item.key
        if unrenderable.contains(key) { return nil }

        if waiting[key] != nil {
            return await withCheckedContinuation { continuation in
                waiting[key, default: []].append(continuation)
            }
        }
        waiting[key] = []

        let url = item.currentURL
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            Covers.queue.addOperation {
                continuation.resume(returning: Covers.render(url, passwords: passwords, height: height))
            }
        }

        if let image { cache.setObject(image, forKey: key as NSString) }
        else { unrenderable.insert(key) }
        for pending in waiting.removeValue(forKey: key) ?? [] {
            pending.resume(returning: image)
        }
        return image
    }

    /// Renders already in flight are left to finish rather than cancelled: resuming their
    /// waiters here as well as at the end of the render would resume twice, and a
    /// continuation resumed twice traps.
    func forget() {
        cache.removeAllObjects()
        unrenderable.removeAll()
        generation &+= 1
    }

    private nonisolated static func render(_ url: URL, passwords: [String], height: CGFloat) -> NSImage? {
        firstPageImage(of: url, passwords: passwords, height: height)
    }
}

/// The first page of a PDF, drawn at a given height. Shared by the shelf's covers and by
/// the duplicate window, which used to be handed a closure that returned nil for every
/// file and so showed two grey rectangles where the whole point is comparing two pages.
func firstPageImage(of url: URL, passwords: [String], height: CGFloat) -> NSImage? {
    guard let document = PDFDocument(url: url) else { return nil }
    if document.isLocked {
        for password in passwords where document.unlock(withPassword: password) { break }
    }
    guard let page = document.page(at: 0) else { return nil }
    let box = page.bounds(for: .mediaBox)
    guard box.height > 0 else { return nil }
    let width = max(1, box.width * (height / box.height))
    return page.thumbnail(of: NSSize(width: width, height: height), for: .mediaBox)
}

enum ViewMode: String, CaseIterable, Identifiable, Equatable {
    case list, catalogue, bibliography, duplicates
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .catalogue: return "Shelf"
        case .bibliography: return "BibTeX"
        case .duplicates: return "Duplicates"
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .catalogue: return "square.grid.2x2"
        case .bibliography: return "text.quote"
        case .duplicates: return "doc.on.doc"
        }
    }
}

// MARK: - Runner

/// Coalesces the scan callback, which fires once per directory read and would otherwise
/// spawn thousands of main-actor hops on a deep tree.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: UInt64
    private var last: UInt64 = 0

    init(milliseconds: UInt64) { interval = milliseconds * 1_000_000 }

    func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- last >= interval else { return false }
        last = now
        return true
    }
}

/// What the reviewer decided about one file. Absent means still to review.
enum Decision: Equatable {
    case confirmed(String)
    /// Already carried out on disk, on its own, ahead of the batch.
    case applied
    case skipped
    /// Marked for the Trash. Nothing happens until Apply, so this is undoable by
    /// reopening the file.
    case deleted
    /// Headed for another folder, under the name it would have been given anyway.
    case moveTo(URL)
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Notification.Name {
    /// Posted by ⌘, and by anything else offering a way into the settings, which are a tab
    /// in the sidebar rather than a window of their own.
    static let showSettings = Notification.Name("PaperShelf.showSettings")
}

// MARK: - Content
