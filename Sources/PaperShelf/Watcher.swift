import Foundation
import CoreServices

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
    private let onChange: @Sendable () -> Void

    init(settle: TimeInterval = 1.2, onChange: @escaping @Sendable () -> Void) {
        self.settle = settle
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ roots: [URL]) {
        stop()
        guard !roots.isEmpty else { return }

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
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
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

    /// Restarts the settle timer on every event, so the work runs once the burst is over
    /// rather than once per file copied.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
