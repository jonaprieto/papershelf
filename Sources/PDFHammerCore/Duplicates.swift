import Foundation
import SQLite3

// MARK: - Incremental duplicate detection
//
// `duplicateGroups(in:passwords:)` (Hammer.swift) is a full three-pass scan: everything the
// library has ever seen, hashed and grouped from scratch, every time it runs. That is right
// for the "Find duplicates" button, which really does mean "check everything now". It is the
// wrong shape for the watcher: a file just arrived, and rehashing the whole shelf to place
// one new arrival costs the whole shelf, not the one file.
//
// `DuplicateIndex` below answers the same question -- is this file a duplicate of something
// already known? -- for one file at a time, in the same priority order `duplicateGroups` uses
// (identical bytes, then same opening text, then similar name), reusing its public building
// blocks (`fileDigest`, `contentKey`, `duplicateKey`) so the two can never disagree about what
// counts as a match. `duplicateGroups` itself is untouched and stays the batch entry point;
// this is a second, incrementally-maintained view of the same signals, not a replacement.
//
// One thing it cannot reuse: `rank(_:_:)`, the tie-break `duplicateGroups` uses to choose the
// keeper, is declared `private` at the top of Hammer.swift, which makes it invisible outside
// that file. `keeperRank` below restates its two rules by hand (see the doc comment on it) --
// if the real one ever changes, this one has to change with it, since nothing enforces that.

/// One book, twice: an incrementally-maintained mirror of `duplicateGroups`'s three passes,
/// so a file the watcher just picked up costs one file's worth of work to place, not a
/// rescan of everything already known.
///
/// Cost per arrival: two dictionary lookups (size, name) in the common case of a file that
/// duplicates nothing -- no PDF I/O at all. A size collision costs one `fileDigest` read of
/// the arriving file, plus, only the first time a same-size bucket ever grows past one
/// member, a one-time digest of the sibling that was already sitting there unhashed. A
/// content-key check costs one `openingText` extraction of the arriving file's first pages,
/// the same read `contentKey` already pays per file in the batch path, just paid once per
/// file instead of once per `duplicateGroups()` call.
public struct DuplicateIndex: Sendable {
    private var items: [String: Item] = [:]
    private var bySize: [Int: Set<String>] = [:]
    private var fileDigests: [String: String] = [:]
    private var byFileDigest: [String: Set<String>] = [:]
    private var contentKeys: [String: String] = [:]
    private var byContentKey: [String: Set<String>] = [:]
    private var byNameKey: [String: Set<String>] = [:]
    /// Once a key has been matched by a stronger pass (identical, then same-text), it is
    /// never reconsidered by a weaker one, mirroring `duplicateGroups`'s own `claimed` set --
    /// except here it persists for the life of the index rather than being rebuilt fresh on
    /// every call, since an incremental index has no "every call" to reset between.
    private var claimed: Set<String> = []
    /// `DuplicateGroup.id`s the user has already looked at and told the app to leave alone.
    /// A group's id is already the content-derived signal that matched it (a hash for
    /// `.identical`, a text digest for `.sameText`, the normalized name for `.likely`, see
    /// `DuplicateGroup` in Hammer.swift) rather than anything tied to which files happened
    /// to be sitting on disk at the time, so dismissing it is dismissing the *match*, not a
    /// specific pair of paths -- a third file that produces the very same id later is, by
    /// that same signal, not new evidence of anything the user hasn't already settled.
    private var dismissed: Set<String>

    public init(dismissed: Set<String> = []) {
        self.dismissed = dismissed
    }

    /// Builds the index from a full library in one pass. Same asymptotic cost as one
    /// `duplicateGroups` call -- hashing and text extraction only happen for files that
    /// collide on size or name -- with any group a full scan would have found instead
    /// surfacing as the return value of inserting that group's second member; a caller
    /// that only wants the finished index can ignore the return values, exactly as
    /// `duplicateGroups` has no equivalent intermediate result to look at either.
    public init(items: [Item], passwords: [String] = [], dismissed: Set<String> = []) {
        self.dismissed = dismissed
        for item in items { _ = insert(item, passwords: passwords) }
    }

    /// Adds one arriving file and reports what it duplicates, if anything. `passwords` is
    /// only consulted if the identical-bytes pass misses and a locked PDF's opening text has
    /// to be read to try the second pass.
    @discardableResult
    public mutating func insert(_ item: Item, passwords: [String] = []) -> DuplicateGroup? {
        items[item.key] = item
        guard let size = item.byteCount else { return matchByName(item) }

        let sizeBucket = bySize[size, default: []]
        bySize[size, default: []].insert(item.key)

        // Pass 1: identical bytes, only among files that already share this exact size.
        if !sizeBucket.isEmpty, let digest = fileDigests[item.key] ?? fileDigest(item.currentURL) {
            fileDigests[item.key] = digest
            // Lazily hash any same-size sibling that has never needed hashing before -- the
            // first file at a given size costs nothing until a second one shows up.
            for siblingKey in sizeBucket where fileDigests[siblingKey] == nil {
                if let sibling = items[siblingKey], let siblingDigest = fileDigest(sibling.currentURL) {
                    fileDigests[siblingKey] = siblingDigest
                    byFileDigest[siblingDigest, default: []].insert(siblingKey)
                }
            }
            let matches = byFileDigest[digest, default: []]
            byFileDigest[digest, default: []].insert(item.key)
            // A real signal match settles this file's fate either way: either it is
            // reported, or its id has been dismissed. Neither case should fall through to
            // the weaker passes below and let a dismissed identical match resurface there
            // as a "likely" one instead.
            if !matches.isEmpty {
                return buildGroup(id: digest, kind: .identical, newItem: item, rawMatches: matches)
            }
        }

        // Pass 2: same opening text, only among files not already claimed by pass 1.
        if let key = contentKeys[item.key] ?? contentKey(for: item, passwords: passwords) {
            contentKeys[item.key] = key
            let matches = byContentKey[key, default: []].subtracting(claimed)
            byContentKey[key, default: []].insert(item.key)
            if !matches.isEmpty {
                return buildGroup(id: "text:" + key, kind: .sameText, newItem: item, rawMatches: matches)
            }
        }

        return matchByName(item)
    }

    /// Drops a file that is no longer on disk, so a later arrival at the same size or name
    /// is never matched against something that has been deleted.
    ///
    /// This does not un-claim whatever the removed file was matched with: if A and B were
    /// found identical and B is now deleted, A stays claimed rather than becoming eligible
    /// for a same-text or name match again. A full rescan would behave the same way in the
    /// one case it matters (A's identical-bytes signal is gone with its only partner), and
    /// treating this as a documented edge rather than one worth chasing keeps this the
    /// small thing it is meant to be.
    public mutating func remove(_ key: String) {
        guard let item = items.removeValue(forKey: key) else { return }
        if let size = item.byteCount { bySize[size]?.remove(key) }
        if let digest = fileDigests.removeValue(forKey: key) { byFileDigest[digest]?.remove(key) }
        if let contentKey = contentKeys.removeValue(forKey: key) { byContentKey[contentKey]?.remove(key) }
        byNameKey[duplicateKey(for: item.sourceName)]?.remove(key)
        claimed.remove(key)
    }

    /// Tells this index that a match has been looked at and kept, so the very next arrival
    /// that would produce the same `DuplicateGroup.id` stops being reported, without
    /// rebuilding the index. Durable storage of the same fact is `DismissedDuplicates`
    /// below; this is the in-memory half that makes it take effect immediately, this run.
    public mutating func dismiss(_ groupID: String) {
        dismissed.insert(groupID)
    }

    public func isDismissed(_ groupID: String) -> Bool {
        dismissed.contains(groupID)
    }

    // Pass 3: similar filename, the last resort, exactly as `duplicateGroups` does it.
    private mutating func matchByName(_ item: Item) -> DuplicateGroup? {
        let key = duplicateKey(for: item.sourceName)
        guard !key.isEmpty else { return nil }
        let matches = byNameKey[key, default: []].subtracting(claimed)
        byNameKey[key, default: []].insert(item.key)
        guard !matches.isEmpty else { return nil }
        return buildGroup(id: "name:" + key, kind: .likely, newItem: item, rawMatches: matches)
    }

    /// `rawMatches` never includes `newItem` itself. Everything in `rawMatches` plus
    /// `newItem` is claimed unconditionally -- a real match on this signal was found, and
    /// nothing here should be reconsidered by a weaker pass whether or not it ends up
    /// reported. A dismissed `id` reports nothing at all; this is coarser than filtering
    /// per pair, but `id` already names the specific match (see the field comment on
    /// `dismissed`), so a dismissed id genuinely has nothing new left to say.
    private mutating func buildGroup(
        id: String, kind: DuplicateGroup.Kind, newItem: Item, rawMatches: Set<String>
    ) -> DuplicateGroup? {
        claimed.formUnion(rawMatches)
        claimed.insert(newItem.key)
        guard !dismissed.contains(id) else { return nil }
        let members = (rawMatches + [newItem.key]).compactMap { items[$0] }
        return DuplicateGroup(id: id, kind: kind, items: members.sorted(by: keeperRank))
    }
}

/// Restates `rank(_:_:)` from Hammer.swift (biggest file first, since a truncated download
/// is smaller, then the shortest name, the one without "(1)" bolted on): that function is
/// `private` there, so this file cannot call it. Kept as a copy rather than made visible
/// over there because widening it is not this round's change to make in that file; if the
/// real tie-break ever changes, this one needs to change with it by hand.
private func keeperRank(_ a: Item, _ b: Item) -> Bool {
    let sizeA = a.byteCount ?? 0, sizeB = b.byteCount ?? 0
    if sizeA != sizeB { return sizeA > sizeB }
    if a.sourceName.count != b.sourceName.count { return a.sourceName.count < b.sourceName.count }
    return a.key < b.key
}

// MARK: - Durable dismissal

// A pair the user has told the app to leave alone must never be reported again, even after
// a relaunch, so this cannot live only in the in-memory `DuplicateIndex` above.
//
// It lives in the library, in `dismissed_duplicates`, rather than in a JSON file of its
// own. The reason is the one the review gave against three separate unlocked files: the
// interface and the MCP server are two processes writing the same state, and a read,
// mutate and blind overwrite loses one side's write. SQLite in WAL mode is what this
// project already runs for that reason.

extension Library {

    /// Stops a match being reported again. Dismissing the same one twice is not an error:
    /// the user pressing keep-both a second time means the same thing as the first.
    public func dismissDuplicate(groupID: String, at date: Date = Date()) throws {
        try run("INSERT OR REPLACE INTO dismissed_duplicates (group_id, dismissed_at) VALUES (?, ?);") {
            statement in
            bindText(statement, 1, groupID)
            bindText(statement, 2, Library.isoString(date))
        }
    }

    public func undismissDuplicate(groupID: String) throws {
        try run("DELETE FROM dismissed_duplicates WHERE group_id = ?;") { statement in
            bindText(statement, 1, groupID)
        }
    }

    /// Everything already decided, for seeding a `DuplicateIndex` at launch.
    public func dismissedDuplicateIDs() throws -> Set<String> {
        try withStatement("SELECT group_id FROM dismissed_duplicates;") { statement in
            var ids: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    ids.insert(String(cString: text))
                }
            }
            return ids
        }
    }
}
