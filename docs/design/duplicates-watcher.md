# duplicates-watcher

## Summary

Today's duplicate detection (Hammer.swift:838-977) is a manual, full-library, three-pass batch scan the user triggers by button or the "d" key; the watcher's absorbChanges (Runner.swift:547-614) never calls it, so nothing about duplicates is incremental or notification-driven yet. UNUserNotificationCenter needs no sandbox entitlement and works with ad-hoc signing on macOS as long as the binary lives in a real, CFBundleIdentifier-bearing .app bundle (which PDF Hammer already is) — no Apple documentation ties it to /Applications or a Developer ID — but its failure mode is silent (granted:false, no dialog, no error) and, per multiple independent sources (not Apple-official), the grant is tied to the app's code-signing identity, so ad-hoc rebuilds (a fresh CDHash every `./build.sh`) can invalidate a previously-granted permission. The design adds a lazy, cache-based DuplicateIndex for O(1)-per-arrival incremental checks, a content-derived and therefore stable DuplicateGroup.id used as the dismissal key, a small JSON-backed dismissal store mirroring Cache.swift's RunCache pattern, and a second Window scene reusing Runner/Covers (which must be hoisted from ContentView to PDFHammerApp) for the review UI — with the existing in-app Duplicates tab kept as the non-silent fallback surface for when the OS notification never fires.

## Design

## Part A — PDFHammerCore: incremental duplicate detection

Add one new type to Hammer.swift (same file as `duplicateGroups`/`rank`/`fileDigest`/`contentKey`/`duplicateKey`, so it can reuse the file-private `rank` function and stay next to the algorithm it mirrors). No existing function is changed; `duplicateGroups(in:passwords:)` stays as the batch/full-rescan entry point used by the manual "Find duplicates" button.

```swift
/// An incrementally-maintained view of the library for duplicate lookups, so a file
/// the watcher just picked up costs one file's worth of work, not a rescan of
/// everything already known. Mirrors `duplicateGroups`'s pass order exactly —
/// identical bytes, then same opening text, then similar name — cheapest first, and
/// never recomputes a hash or a text digest for a file already indexed.
public struct DuplicateIndex: Sendable {
    private var items: [String: Item] = [:]                // item key -> Item
    private var bySize: [Int: Set<String>] = [:]            // byteCount -> item keys
    private var fileDigests: [String: String] = [:]         // item key -> SHA-256 (only for size collisions)
    private var byFileDigest: [String: Set<String>] = [:]   // SHA-256 -> item keys
    private var contentKeys: [String: String] = [:]         // item key -> contentKey (only computed once needed)
    private var byContentKey: [String: Set<String>] = [:]   // contentKey -> item keys
    private var byNameKey: [String: Set<String>] = [:]      // duplicateKey(name) -> item keys
    private var claimed: Set<String> = []                   // item keys already matched to a group

    public init() {}

    /// Builds the index from a full library in one pass: same asymptotic cost as one
    /// `duplicateGroups` call, but hashing/text-extraction only happens for files that
    /// actually collide on size or name, same as today.
    public init(items: [Item], passwords: [String] = []) {
        for item in items { _ = insert(item, passwords: passwords) }
    }

    /// Adds one file and reports what it duplicates, if anything. `passwords` is only
    /// used if the identical-bytes pass misses and a locked PDF's opening text has to
    /// be read.
    @discardableResult
    public mutating func insert(_ item: Item, passwords: [String] = []) -> DuplicateGroup? {
        items[item.key] = item
        guard let size = item.byteCount else {
            return matchByName(item)
        }
        let sizeBucket = bySize[size, default: []]
        bySize[size, default: []].insert(item.key)

        // Pass 1: identical bytes, only among files that already share this exact size.
        if !sizeBucket.isEmpty {
            let digest = fileDigests[item.key] ?? fileDigest(item.currentURL)
            if let digest {
                fileDigests[item.key] = digest
                // Lazily hash any same-size sibling that has never needed hashing before.
                for siblingKey in sizeBucket where fileDigests[siblingKey] == nil {
                    if let sibling = items[siblingKey], let d = fileDigest(sibling.currentURL) {
                        fileDigests[siblingKey] = d
                        byFileDigest[d, default: []].insert(siblingKey)
                    }
                }
                let matches = byFileDigest[digest, default: []]
                byFileDigest[digest, default: []].insert(item.key)
                if !matches.isEmpty {
                    return buildGroup(id: digest, kind: .identical, keys: matches.union([item.key]))
                }
            }
        }

        // Pass 2: same opening text, only among files not already claimed as identical.
        if let key = contentKeys[item.key] ?? contentKey(for: item, passwords: passwords) {
            contentKeys[item.key] = key
            let matches = byContentKey[key, default: []].subtracting(claimed)
            byContentKey[key, default: []].insert(item.key)
            if !matches.isEmpty {
                return buildGroup(id: "text:" + key, kind: .sameText, keys: matches.union([item.key]))
            }
        }

        return matchByName(item)
    }

    /// Drops a file that is no longer on disk, so a later arrival at the same size or
    /// name is not matched against something deleted.
    public mutating func remove(_ key: String) {
        guard let item = items.removeValue(forKey: key) else { return }
        if let size = item.byteCount { bySize[size]?.remove(key) }
        if let digest = fileDigests.removeValue(forKey: key) { byFileDigest[digest]?.remove(key) }
        if let ck = contentKeys.removeValue(forKey: key) { byContentKey[ck]?.remove(key) }
        byNameKey[duplicateKey(for: item.sourceName)]?.remove(key)
        claimed.remove(key)
    }

    // Pass 3: similar filename, the last resort, exactly as duplicateGroups does it.
    private mutating func matchByName(_ item: Item) -> DuplicateGroup? {
        let key = duplicateKey(for: item.sourceName)
        guard !key.isEmpty else { return nil }
        let matches = byNameKey[key, default: []].subtracting(claimed)
        byNameKey[key, default: []].insert(item.key)
        guard !matches.isEmpty else { return nil }
        return buildGroup(id: "name:" + key, kind: .likely, keys: matches.union([item.key]))
    }

    private mutating func buildGroup(id: String, kind: DuplicateGroup.Kind, keys: Set<String>) -> DuplicateGroup {
        claimed.formUnion(keys)
        let group = DuplicateGroup(id: id, kind: kind,
                                    items: keys.compactMap { items[$0] }.sorted(by: rank))
        return group
    }
}
```

Cost model for one arrival: 2 dictionary lookups (size, name) in the common non-duplicate case — no PDF I/O at all. A size collision costs one `fileDigest` read of the new file (chunked, proportional to its own size) plus, only the first time that bucket ever grows past 1, a one-time digest of the original sibling — never repeated after that. A content-key check costs one `openingText` extraction of the new file's first 3 pages — the same cost `contentKey` already pays per file in the batch path, just paid once instead of on every `findDuplicates()` call.

Wiring into `Runner` (Runner.swift): add `private var duplicateIndex = DuplicateIndex()`, seed it in `preview(...)` and `showCached(...)` right after `results` is established (`self.duplicateIndex = DuplicateIndex(items: out, passwords: options.passwords)`), and in `absorbChanges(roots:options:fingerprint:)` call, once for each freshly-arrived item and once for each vanished key:

```swift
for item in arrived.values {
    if let group = duplicateIndex.insert(item, passwords: options.passwords) {
        considerNotifying(group)   // part D
    }
}
for key in vanished { duplicateIndex.remove(key) }
```

## Part B — Notification signing/authorization: what is verified and what to build defensively around

Verified, not guessed:
- UNUserNotificationCenter needs no sandbox entitlement for local notifications (Apple's own doc abstract says so explicitly) and no Developer ID is documented as a requirement anywhere in Apple's docs — this app already satisfies the one real requirement (a genuine `.app` bundle with a `CFBundleIdentifier`, both true today per Info.plist and build.sh).
- Ad-hoc signing (`codesign --sign -`, exactly what build.sh already does) is sufficient for local notifications per a working third-party example; no Apple source says otherwise.
- `requestAuthorization` prompts only once; every later call resolves silently from the stored answer, and if the answer is `.denied`, `add(_:)` still "succeeds" (the completion handler reports no error) but the notification is simply never shown — this is Apple-documented behavior, not a guess, and it means a denied/broken permission state is invisible to the calling code unless it explicitly checks.
- The concrete, sourced risk for this project specifically: ad-hoc signing produces a new code-signing identity (CDHash) on every `./build.sh` rebuild, and multiple independent developer sources (not Apple) report that macOS's permission grants keyed to that identity — notification alert state is reported to live in `~/Library/Preferences/com.apple.ncprefs.plist` — can reset across such rebuilds. This is corroborated across several independent reports but is not an Apple-published guarantee, so I flag it as **UNVERIFIED (Apple-official)** even though the underlying evidence is solid.

Design consequence: never make the OS notification the only way a duplicate becomes visible. Concretely:
1. At launch, call `UNUserNotificationCenter.current().getNotificationSettings { settings in ... }` (verified signature) and record `settings.authorizationStatus` on a small `@Published var notificationsAvailable: Bool` on `Runner` or a dedicated notifier object.
2. `considerNotifying(group)` always does two things regardless of authorization state: (a) merges the group into `Runner.duplicates` so the existing Duplicates tab (Catalogue.swift) shows it immediately — this is the guaranteed, always-visible path; (b) attempts `UNUserNotificationCenter.current().add(request)` as a convenience, and does not treat its failure as anything the user needs to see, because the tab already carries the information.
3. Optionally surface a small persistent badge/count on the sidebar's "Duplicates" `ViewMode` tab (a `Text` badge next to the tab label already rendered around Catalogue.swift:800) so a duplicate found while the user is looking at the window, but with a denied/broken OS notification, still gets noticed.

## Part C — Review window

New `Window(id: "duplicate-review", for: String.self)` scene in `PDFHammerApp` (Shell.swift), value = `DuplicateGroup.id`:

```swift
Window("Duplicate", id: "duplicate-review") { EmptyView() }   // placeholder before the refactor below
```

Requires hoisting `runner` and `covers` from `ContentView` (currently `@StateObject private var runner = Runner()` / `@StateObject private var covers = Covers()` at ContentView.swift:57-58) up to `PDFHammerApp`, then passing them into both scenes:

```swift
@main
struct PDFHammerApp: App {
    @StateObject private var chrome = Chrome()
    @StateObject private var runner = Runner()
    @StateObject private var covers = Covers()

    var body: some Scene {
        Window("PDF Hammer", id: "main") {
            ContentView(chrome: chrome, runner: runner, covers: covers)
        }
        WindowGroup("Duplicate", id: "duplicate-review", for: String.self) { $groupID in
            if let groupID, let group = runner.duplicates.first(where: { $0.id == groupID }) {
                DuplicateReviewView(runner: runner, covers: covers, group: group,
                                     passwords: /* same parsed-passwords helper ContentView uses */)
            }
        }
        .defaultSize(width: 720, height: 480)
        Settings { SettingsView() }
        .commands { /* unchanged */ }
    }
}
```

`ContentView` changes its two `@StateObject` declarations to `@ObservedObject let runner: Runner` / `@ObservedObject let covers: Covers`, passed in from the initializer — everything else in ContentView that already reads `runner`/`covers` is unaffected.

`DuplicateReviewView`, the content the user needs to decide:

```swift
struct DuplicateReviewView: View {
    @ObservedObject var runner: Runner
    @ObservedObject var covers: Covers
    let group: DuplicateGroup
    let passwords: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 20) {
            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: covers.cover(for: item, passwords: passwords, height: 320)
                          ?? NSImage())
                        .resizable().scaledToFit()
                        .frame(height: 320)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    Text(item.sourceName).font(.headline).lineLimit(2)
                    Text(item.relativePath).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Size", value: ByteCountFormatter.string(
                        fromByteCount: Int64(item.byteCount ?? 0), countStyle: .file))
                    LabeledContent("Pages", value: "\(item.pageCount ?? 0)")
                    LabeledContent("Modified", value: (item.modifiedDate ?? .distantPast)
                        .formatted(date: .abbreviated, time: .shortened))
                    if let metadataDate = item.metadataDate {
                        LabeledContent("Document date", value: metadataDate.formatted(date: .abbreviated, time: .omitted))
                    }
                    if item.key == group.keeper.key {
                        Label("Better copy", systemImage: "star.fill").foregroundStyle(.green)
                    }
                    Button(item.key == group.keeper.key ? "Keep this" : "Keep this instead") {
                        runner.keep(item, inGroup: group.id)
                    }
                    .disabled(item.key == group.keeper.key)
                }
            }
        }
        .padding(24)
        .toolbar {
            ToolbarItemGroup {
                Button("Trash the other\(group.extras.count == 1 ? "" : "s")") {
                    runner.trashExtras(of: group.id)
                    dismiss()
                }
                Button("Not a duplicate") {
                    runner.dismissDuplicate(group.id)
                    dismiss()
                }
                Button("Ask me later") { dismiss() }
            }
        }
    }
}
```

Every field shown (`sourceName`, `relativePath`, `byteCount`, `pageCount`, `modifiedDate`, `metadataDate`, `keeper`/`rank`) and every action (`keep(_:inGroup:)`, `trashExtras(of:)`) already exists on `Item`/`DuplicateGroup`/`Runner` today — the window is new UI over existing model surface, plus one new method (`dismissDuplicate`, part D) and reuse of the existing `Covers.cover(for:passwords:height:)` thumbnail renderer at a larger height than the catalogue grid uses.

## Part D — "New" vs. already-dismissed, and where dismissal state lives

Two separate concerns, both keyed on `DuplicateGroup.id` because that id is already content-derived and stable (a SHA-256 digest, a text-digest, or a normalized-name key — never an `Item.id`, which is explicitly a fresh, unpersisted UUID per Hammer.swift:544-548):

1. **Per-session de-duplication of the notification itself** (in memory only, on `Runner`): `private var notifiedGroupIDs: Set<String> = []`. `considerNotifying(group)` only calls `notifier.post(for: group)` when `!notifiedGroupIDs.contains(group.id)`, then inserts immediately regardless of whether the user acts — so the same still-open pair is not re-notified every time the watcher's settle timer fires for unrelated activity in the folder, but a fresh app launch will notify once more for anything still outstanding (a deliberate "gentle reminder on relaunch," not a bug).

2. **Permanent dismissal** ("not a duplicate" / "leave both"), persisted to disk so it survives relaunch, mirroring `RunCache`'s pattern exactly (`/Users/jonaprieto/research/pdf-hammer/Sources/PDFHammerCore/Cache.swift`):

```swift
// PDFHammerCore/Cache.swift, alongside RunCache
public struct DismissedDuplicates: Codable, Sendable {
    public var ids: Set<String>
    public init(ids: Set<String> = []) { self.ids = ids }
}

public func dismissedDuplicatesURL() -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first else { return nil }
    let folder = base.appendingPathComponent("PDF Hammer", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("dismissed-duplicates.json")
}

public func loadDismissedDuplicates() -> DismissedDuplicates {
    guard let url = dismissedDuplicatesURL(), let data = try? Data(contentsOf: url),
          let value = try? JSONDecoder().decode(DismissedDuplicates.self, from: data) else {
        return DismissedDuplicates()
    }
    return value
}

public func saveDismissedDuplicates(_ value: DismissedDuplicates) {
    guard let url = dismissedDuplicatesURL(), let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: .atomic)
}
```

`Runner` loads this once at init (`private var dismissed = loadDismissedDuplicates()`), and:

```swift
func dismissDuplicate(_ id: String) {
    dismissed.ids.insert(id)
    saveDismissedDuplicates(dismissed)
    duplicates.removeAll { $0.id == id }
}
```

`considerNotifying(group)` becomes:
```swift
private func considerNotifying(_ group: DuplicateGroup) {
    guard !dismissed.ids.contains(group.id) else { return }
    mergeIntoDuplicates(group)
    guard !notifiedGroupIDs.contains(group.id) else { return }
    notifiedGroupIDs.insert(group.id)
    notifier.post(for: group)
}
```

This directly answers part 4: a pair is "new" exactly when its content-derived id is absent from the persisted `dismissed.ids` set; a pair the user already told the app to ignore never resurfaces even after the file is renamed, moved, or the app relaunched, because the id does not depend on the current filename or path for the `.identical`/`.sameText` kinds (only `.likely` depends on the normalized filename, which is inherent to that heuristic already, per its own doc comment at Hammer.swift:850-857 calling it "a guess"). Dismissing one specific pairing via `.likely`'s name-derived id will not suppress a later, different `.identical`/`.sameText` finding between the same two files if their bytes are later found to genuinely match — which is correct, since that would be new, stronger evidence.

## Verified facts

- duplicateGroups runs three passes in priority order — identical bytes, same opening-page text, similar filename — and is exported from PDFHammerCore.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammerCore/Hammer.swift:913-977

- Pass 1 groups items by cached byteCount (no I/O) and only SHA-256-hashes files inside a size collision, in parallel via DispatchQueue.concurrentPerform, re-hashing every candidate on every call (no caching).
  EVIDENCE: Hammer.swift:913-929, fileDigest at Hammer.swift:838-847

- Pass 2 (sameText) computes contentKey for every item not already claimed as identical: extracts text from the first 3 pages via openingText, requires >=240 letters/digits, hashes it, and prefixes with pageCount so two different works with matching boilerplate cannot collide.
  EVIDENCE: Hammer.swift:889-911, 946-964; openingText declared at /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammerCore/BookGuess.swift:85

- Pass 3 (likely) strips dates and one trailing copy-marker/number from the filename and keeps only letters+digits, on whatever is still unclaimed after passes 1-2.
  EVIDENCE: Hammer.swift:818-836, 966-974

- DuplicateGroup.id is a stable, content-derived string per kind: the SHA-256 digest itself for .identical, "text:"+contentKey for .sameText, "name:"+duplicateKey for .likely — not tied to any Item.id (Item.id is a fresh UUID per process, explicitly excluded from Codable persistence).
  EVIDENCE: Hammer.swift:941, 961, 973 (id construction); Item.id comment at Hammer.swift:544-548 ("`id` is deliberately absent... `key` is the identity that survives")

- findDuplicates() is only invoked from three UI call sites (a keyboard shortcut and two buttons) — never from the watcher's absorbChanges path — and it always re-scans the entire current `results` snapshot from scratch.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammer/Catalogue.swift:251,529,564,943; Runner.swift:420-437

- The watcher (FolderWatcher, FSEvents-backed) only triggers absorbChanges, which merges new/vanished files into `results` and re-derives per-item state; it never touches `duplicates`.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammer/Watcher.swift:9-74; ContentView.swift:925-940; Runner.swift:547-614 (no reference to duplicates, duplicateGroups, or findDuplicates in this function)

- The app has no entitlements file and is code-signed ad-hoc (`codesign --force --sign -`), with bundle identifier com.jonaprieto.pdfhammer and installation to /Applications only happening if `--install` is passed to build.sh.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/build.sh:1-27 (`codesign --force --sign - "$APP"`); Resources/Info.plist CFBundleIdentifier com.jonaprieto.pdfhammer; `find ... -iname *.entitlements` returned nothing

- UNUserNotificationCenter.requestAuthorization signature and behavior: prompts only on first call, subsequent calls resolve from the stored answer, and it must be called before scheduling any local notification.
  EVIDENCE: https://developer.apple.com/tutorials/data/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:).json — quote: "The first call prompts the user; subsequent calls do not. The system stores the user's response."

- Apple's own UNUserNotificationCenter overview lists no sandbox entitlement as a requirement for basic (local) use.
  EVIDENCE: https://developer.apple.com/tutorials/data/documentation/usernotifications/unusernotificationcenter.json — quote: "No Specific Entitlements Required"

- The delegate callback for a clicked notification or action button is userNotificationCenter(_:didReceive:withCompletionHandler:); it fires for a custom action, a plain dismiss, or a launch from the notification, and the app must call completionHandler when done.
  EVIDENCE: https://developer.apple.com/tutorials/data/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:didreceive:withcompletionhandler:).json

- UNNotificationAction and UNNotificationCategory initializers verified exactly: init(identifier:title:options:) and init(identifier:actions:intentIdentifiers:options:).
  EVIDENCE: https://developer.apple.com/tutorials/data/documentation/usernotifications/unnotificationaction/init(identifier:title:options:).json and .../unnotificationcategory/init(identifier:actions:intentidentifiers:options:).json

- UNUserNotificationCenter.add(_:withCompletionHandler:) schedules local notifications only and delivers immediately when the request has no trigger.
  EVIDENCE: https://developer.apple.com/tutorials/data/documentation/usernotifications/unusernotificationcenter/add(_:withcompletionhandler:).json

- A third-party writeup of getting UNUserNotificationCenter working from a hand-built (non-Xcode) bundle states the binary must live inside a signed .app with a CFBundleIdentifier or authorization requests silently fail, and demonstrates this working with plain ad-hoc signing (`codesign -s -`).
  EVIDENCE: https://codeandcircuits.com/posts/2026-03-04-tmux-desktop-notifications/index.html — summarized quote: "UNUserNotificationCenter requires the binary to live inside a signed .app bundle. Without it, authorization requests silently fail."

- Community sources describe macOS privacy/notification-style permissions as keyed to the app's code-signing requirement (csreq/CDHash); ad-hoc signing produces a new CDHash on every rebuild, which multiple independent sources say revokes previously granted permissions on rebuild, and one source states notification alert state specifically lives in ~/Library/Preferences/com.apple.ncprefs.plist.
  EVIDENCE: WebSearch results summarizing evoleinik.com/posts/macos-dev-signing-preserve-permissions and related threads — this is community/developer-forum consensus, not an Apple-published statement, so treat as corroborated-but-unofficial

- No Apple documentation found ties UNUserNotificationCenter functionality to the app being located in /Applications or to Developer ID signing specifically (as opposed to any real code signature); claims to that effect in general web search summaries were unsourced inferences, not Apple citations.
  EVIDENCE: Absence in fetched pages: https://developer.apple.com/tutorials/data/documentation/usernotifications/unusernotificationcenter.json and the requestAuthorization/add(_:) doc pages make no mention of app location or Developer ID

- Runner and Covers are both owned as @StateObject by ContentView (a single Window scene), not by the App struct, so no other Window scene can currently reach the live duplicate/decision state.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammer/ContentView.swift:57-58; PDFHammerApp only declares Window("PDF Hammer", id: "main") and Settings — Shell.swift:28-62

- SwiftUI's openWindow(value:) requires the value type to conform to Decodable & Encodable & Hashable and is available on macOS 13+, compatible with this project's macOS 14 minimum.
  EVIDENCE: https://developer.apple.com/tutorials/data/documentation/swiftui/openwindowaction/callasfunction(value:).json

- The project already has a precedent for a small Codable, disk-persisted store in Application Support (RunCache), which the proposed dismissal store should mirror.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammerCore/Cache.swift:1-53

- The existing Duplicates tab (ViewMode.duplicates) already renders groups with a keeper star, filenames, relative paths, and byte sizes, and offers per-group "Trash the other N" and per-item "keep" — but shows no dates, no page counts, no thumbnails, and lives inside the main window, not a separate review window.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammer/Catalogue.swift:1381-1470 (duplicateLabel/Icon/Colour/Explanation, DuplicateRow); Runner.swift:54-56 (duplicates/duplicateKind state)

- First-page thumbnail rendering already exists and is reusable as-is for a side-by-side comparison: Covers.cover(for:passwords:height:) renders page 0 via PDFKit's PDFPage.thumbnail(of:for:), cached in an NSCache, off-main-thread via a 4-way OperationQueue.
  EVIDENCE: /Users/jonaprieto/research/pdf-hammer/Sources/PDFHammer/Shell.swift:69-121

- The rank(_:_:) tie-breaker used to pick DuplicateGroup.keeper (biggest file, then shortest name, then key) is a file-private top-level function in Hammer.swift, so any new incremental-index code that needs to build a DuplicateGroup the same way should live in the same file to reuse it without making it public API.
  EVIDENCE: Hammer.swift:880-887 (`private func rank`)


## Risks

- UNVERIFIED as an Apple-official guarantee: that ad-hoc rebuilds reset notification authorization. The evidence is strong and consistent across multiple independent developer sources describing TCC-style permissions keyed to code-signing identity, and one source specifically names ~/Library/Preferences/com.apple.ncprefs.plist for notification alert state, but no Apple documentation page confirms this mechanism for UNUserNotificationCenter specifically. Verify empirically before relying on it: build twice with build.sh, grant permission after the first build, then check whether the second (freshly re-signed) build still shows as authorized.

- Hoisting Runner and Covers from ContentView to PDFHammerApp is a real, non-trivial refactor (not just adding a window) — every place that currently assumes `@StateObject` ownership semantics inside ContentView (e.g. anything relying on Runner being freshly created exactly once when ContentView's view identity changes) needs re-auditing after switching to `@ObservedObject let`.

- The per-session notifiedGroupIDs design means a duplicate a user has seen and closed with "Ask me later" will notify again on next app launch, indefinitely, until either dismissed or resolved by trashing — this is a deliberate choice in the design above, but it should be confirmed with the user/product owner rather than assumed to be the desired behavior.

- The `.likely` (name-only) group id is derived purely from the normalized filename, so two unrelated documents that happen to share a normalized name in different folders will be treated as the same dismissal target; this is an existing property of duplicateKey/duplicateGroups (not introduced by this design) but becomes more consequential once dismissals persist indefinitely across sessions.

- DuplicateIndex must be kept perfectly in sync with `results`: any code path that mutates `results` outside of `preview`/`showCached`/`absorbChanges` (for example a rename that changes `byteCount` was not found, but any future one would) must also update the index or call `remove`+`insert`, or the index will silently miss or misreport a match. This wasn't audited beyond the three call sites identified.

- WebFetch on JS-rendered Apple documentation pages (the human-facing HTML) returned only a page title with no body content and, when re-prompted, a smaller/faster summarization model fabricated a specific entitlement name (`com.apple.security.personal-information.notifications`) that does not appear anywhere in verified Apple documentation and should be treated as a hallucination, not a fact — I did not rely on it and instead used Apple's machine-readable doc JSON (`developer.apple.com/tutorials/data/...json`) for every verified claim above, but this is a reminder that the same failure mode can recur on other Apple doc URLs in this environment.


## Unverified (do not build on this without checking)

- Whether notification authorization state is empirically reset by an ad-hoc rebuild on this specific machine/macOS version — not tested, only corroborated by third-party reports.

- Whether running PDF Hammer straight from dist/ (never copied to /Applications, never quarantined since it was locally built) has any different notification behavior than running it from /Applications — no Apple source ties behavior to install location, but this project's own build.sh was not tested against a real requestAuthorization call during this research.

- The exact enum cases and current names of UNAuthorizationStatus (e.g. .notDetermined/.denied/.authorized/.provisional/.ephemeral) were not re-verified against Apple's JSON doc API in this session and are stated from general knowledge rather than a fetched citation in this task.

- Whether UNNotificationAction's `.foreground` option name is exactly right for bringing the app forward when the action button is tapped — not independently re-verified beyond the general UNNotificationActionOptions family; should be checked against Apple's UNNotificationActionOptions doc page before implementation.

- Whether any other code path in the app (beyond the three call sites of findDuplicates and the one absorbChanges) mutates `results` in a way that would desynchronize a persistent DuplicateIndex — only the paths found by direct grep were reviewed.
