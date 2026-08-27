import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PDFHammerCore

/// Window chrome the menu bar needs to reach. The split view draws its own sidebar
/// button, so the menu supplies only the shortcut.
@MainActor
final class Chrome: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// Set by the window so the menu can reach the runner without owning it.
    @Published var undo: () -> Void = {}
    @Published var canUndo = false
    /// Hides everything that is about deciding, leaving the page.
    @AppStorage("readingMode") var reading = false
    /// Shared with the inspector through the same keys, so the menu can reach them.
    @AppStorage("notesShown") var notesShown = false
    @AppStorage("contentsShown") var contentsShown = false

    func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.18)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}

@main
struct PDFHammerApp: App {
    @StateObject private var chrome = Chrome()

    var body: some Scene {
        Window("PDF Hammer", id: "main") {
            ContentView(chrome: chrome)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // No Settings scene to open any more: ⌘, selects the settings tab in the
            // sidebar, which is where the settings now live.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: chrome.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!chrome.canUndo)
            }
            CommandGroup(after: .sidebar) {
                Button(chrome.reading ? "Leave Reading Mode" : "Reading Mode") {
                    chrome.reading.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(chrome.notesShown ? "Hide Notes" : "Show Notes") {
                    chrome.notesShown.toggle()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(chrome.contentsShown ? "Hide Contents" : "Show Contents") {
                    chrome.contentsShown.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Toggle Sidebar", action: chrome.toggleSidebar)
                    .keyboardShortcut("b", modifiers: .command)
            }
        }
    }
}

// MARK: - Covers

/// Renders and caches first-page thumbnails. Nothing is drawn until a card asks for it,
/// so a shelf of thousands costs only what is on screen.
@MainActor
final class Covers: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    /// Bumped when a render lands, to redraw the cards waiting on one.
    @Published private(set) var revision = 0

    /// Four at a time: enough to fill a scroll, few enough to leave the UI responsive.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() { cache.countLimit = 400 }

    func cover(for item: Item, passwords: [String], height: CGFloat) -> NSImage? {
        if let hit = cache.object(forKey: item.key as NSString) { return hit }
        guard !inFlight.contains(item.key) else { return nil }
        inFlight.insert(item.key)

        let url = item.currentURL
        let key = item.key
        Covers.queue.addOperation { [weak self] in
            let image = Covers.render(url, passwords: passwords, height: height)
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(key)
                guard let image else { return }
                self.cache.setObject(image, forKey: key as NSString)
                self.revision &+= 1
            }
        }
        return nil
    }

    func forget() {
        cache.removeAllObjects()
        inFlight.removeAll()
        revision &+= 1
    }

    private nonisolated static func render(_ url: URL, passwords: [String], height: CGFloat) -> NSImage? {
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
}

enum ViewMode: String, CaseIterable, Identifiable {
    case list, catalogue, bibliography, duplicates
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .catalogue: return "Catalogue"
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

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// Resolves per appearance, so it follows both the system theme and an explicit
    /// override set on `NSApp.appearance`.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension Notification.Name {
    /// Posted by ⌘, and by anything else offering a way into the settings, which are a tab
    /// in the sidebar rather than a window of their own.
    static let showSettings = Notification.Name("PDFHammer.showSettings")
}

func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// MARK: - Content
