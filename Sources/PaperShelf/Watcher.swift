import Foundation
import CoreServices
import PaperShelfCore

/// Watches the selected folders and reports when something under them changes.
///
/// FSEvents rather than a poll: a shelf of tens of thousands of files cannot be restatted
/// on a timer, and the kernel already knows. Events are coalesced, because copying a
/// folder in produces a burst of them and the useful moment is when the burst stops.
///
/// This coalescing is also why `Library.indexDocuments` (`Library.swift`) is safe to call from
/// whatever `onChange` triggers: one settled tick here is meant to become one rescan and
/// one batched write to the library, not one write per file changed, the same way a
/// thousand-file folder is one transaction rather than a thousand.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "papershelf.watcher")
    private let settle: TimeInterval
    /// Handed the places that changed during the burst, or nil when the burst said too much
    /// or too little to scope a rescan by: the stream fell behind, a root itself moved, or
    /// more places changed than a scoped walk is worth (`scopedRescanLimit`).
    private let onChange: @Sendable ([ChangedPlace]?) -> Void
    /// What the current burst has touched so far. Only ever read and written on `queue`,
    /// which is where the stream delivers and where the settle timer fires.
    private var gathered = Set<ChangedPlace>()
    private var everything = false
    /// The roots as plain paths, so an event can be read against them without building a
    /// URL per event. Both spellings of each: FSEvents answers with the real path, so a
    /// source picked through a link (`/var/...`, which is `/private/var/...`) is reported
    /// under a name the selection never had.
    private var roots: [String] = []

    init(settle: TimeInterval = 1.2, onChange: @escaping @Sendable ([ChangedPlace]?) -> Void) {
        self.settle = settle
        self.onChange = onChange
    }

    deinit { stop() }

    /// What the filesystem itself calls this path.
    ///
    /// Not `resolvingSymlinksInPath()`, which goes the other way on the one case that
    /// matters here: given `/private/var/folders/...` it answers `/var/folders/...`, while
    /// FSEvents reports the `/private` spelling. A source picked through `/var` would then
    /// match none of its own events and the watcher would sit there quietly.
    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether one event could change what a scan of the sources would find.
    ///
    /// A source folder is often also a working directory: a checkout, a project tree, a
    /// whole research directory. Those are never quiet. One `swift build` writes thousands
    /// of files, and every burst of them used to cost a full rescan of the source, which
    /// on seventy thousand entries is half a second across every core, over and over, for
    /// as long as you are working. None of those files is a PDF, and none of them sits
    /// anywhere a scan would look.
    ///
    /// So: a file matters only if it is a PDF. A directory always matters, because a
    /// folder moved in or renamed carries whatever is under it and FSEvents reports the
    /// folder rather than its contents. Anything under a hidden component matters neither
    /// way, since the walk passes `.skipsHiddenFiles` and so cannot find a file in
    /// `.git` or `.build` however much they churn.
    ///
    /// Only what is hidden *below a root* is dropped. A source can itself live under a
    /// dotted folder, and a person who points the app at one still expects it scanned.
    static func mayChangeScan(_ path: String, isDirectory: Bool, under roots: [String]) -> Bool {
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") })
        else { return false }
        let below = path.dropFirst(root.count).split(separator: "/")
        guard !below.contains(where: { $0.hasPrefix(".") }) else { return false }
        return isDirectory || path.lowercased().hasSuffix(".pdf")
    }

    func watch(_ roots: [URL]) {
        stop()
        guard !roots.isEmpty else { return }
        self.roots = roots.flatMap { [$0.path, FolderWatcher.realPath($0)].compactMap { $0 } }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let paths = roots.map(\.path) as CFArray
        // A one-second latency inside FSEvents, and a settle window on top: two stages of
        // coalescing, because an unpack or a sync can run for a while.
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                // CFTypes, so the paths arrive as an array of strings rather than as a C
                // array this would have to walk by hand.
                let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let lookAgain = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                        | kFSEventStreamEventFlagRootChanged)
                for index in 0..<count {
                    let flag = flags[index]
                    // More happened than the stream could keep up with, or a source itself
                    // moved. Neither names the places that changed, so everything is looked
                    // at again.
                    if flag & lookAgain != 0 {
                        watcher.note(nil)
                        continue
                    }
                    guard index < changed.count else { continue }
                    let isDirectory =
                        flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                    guard FolderWatcher.mayChangeScan(changed[index], isDirectory: isDirectory,
                                                      under: watcher.roots) else { continue }
                    let url = URL(fileURLWithPath: changed[index])
                    watcher.note(isDirectory ? .folder(url) : .file(url))
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Adds one place to the burst, or nil for "look at everything", and restarts the settle
    /// timer, so the work runs once the burst is over rather than once per file copied.
    ///
    /// The places are kept rather than thrown away. Knowing only that something changed
    /// meant walking every folder of every source to find out what, and a source that is
    /// also a working tree changes constantly; knowing where lets the runner walk the
    /// folder somebody saved into.
    private func note(_ place: ChangedPlace?) {
        if let place, !everything {
            gathered.insert(place)
            if gathered.count > scopedRescanLimit { everything = true }
        } else {
            everything = true
        }
        if everything { gathered.removeAll() }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let places = self.everything ? nil : Array(self.gathered)
            self.gathered.removeAll()
            self.everything = false
            self.onChange(places)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
