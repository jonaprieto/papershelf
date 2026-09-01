import Foundation
import CryptoKit
import PaperShelfCore

/// A rename that has been worked out but not done.
///
/// On disk, not in memory. This revision of the protocol is stateless and the client is
/// free to restart the server between the call that proposes a rename and the call that
/// applies it, so a plan held in a variable would be gone exactly when it was needed.
struct RenamePlan: Codable {
    struct Move: Codable {
        let from: String
        let to: String
        /// What the file was when the plan was made. Both are re-checked before anything
        /// moves, so a file edited in between stops the whole plan rather than being
        /// renamed on the strength of a stale reading.
        ///
        /// `modified` is stored as exact epoch seconds rather than as a `Date` run through
        /// `JSONEncoder`'s `.iso8601` strategy: that strategy truncates to whole seconds, so
        /// a file's modification time read, written, and read back again would already
        /// disagree with itself on any fraction of a second, and the comparison this exists
        /// to make would only ever pass by coincidence. A `Double` round-trips through JSON
        /// exactly.
        let bytes: Int
        let modified: Double
        /// What kind of change this actually is, from `process(jobs:options:)` at the
        /// moment the plan was built: an ordinary rename, or one that also decrypts the
        /// document because a saved password now unlocks it. A locked file's destination
        /// name can change from the naming rules alone, with nothing else here telling a
        /// rename apart from a rename that has quietly become a decryption; recording the
        /// status and re-checking it at apply time (`apply_file_changes`, `WriteTools.swift`)
        /// is what catches a password added to or removed from the app's saved list while
        /// this plan sat waiting, since that comparison is otherwise blind to anything but
        /// the two filenames.
        let status: Status
    }

    /// The plan's own hash, which is also its name on disk. Built by `planToken` from every
    /// field below that affects what applying the plan does, not only `moves`: two
    /// proposals over the same files with different backup settings, say, must not collide
    /// on one token and one filename, since applying either one only ever consults the
    /// settings its own token's plan recorded. `readPlan` recomputes this from what it
    /// decoded and refuses the plan if it does not match, which is what makes "a plan
    /// cannot drift out from under a token issued for it" an enforced fact rather than
    /// something that merely tends to be true.
    let token: String
    let createdAt: Date
    let folder: String
    let recursive: Bool
    let casing: String
    let separator: String
    let stripSymbols: Bool
    let stripDiacritics: Bool
    let asciiOnly: Bool
    let dropLeadingArticles: Bool
    let maxLength: Int
    let datePosition: String
    let dateFormat: String
    let backupEnabled: Bool
    let backupFolderName: String
    let backupCustomPath: String?
    let moves: [Move]

    /// Fifteen minutes. Long enough for a person to read a list of renames and answer,
    /// short enough that a plan cannot be applied against a folder nobody has looked at
    /// since yesterday.
    static let lifetime: TimeInterval = 900

    var isExpired: Bool { Date().timeIntervalSince(createdAt) > Self.lifetime }

    var rules: NameRules {
        NameRules(casing: NameRules.Casing(rawValue: casing) ?? .lowercase,
                  separator: NameRules.Separator(rawValue: separator) ?? .keep,
                  stripSymbols: stripSymbols,
                  stripDiacritics: stripDiacritics,
                  asciiOnly: asciiOnly,
                  dropLeadingArticles: dropLeadingArticles,
                  maxLength: maxLength,
                  datePosition: NameRules.DatePosition(rawValue: datePosition) ?? .prefix,
                  dateFormat: NameRules.DateFormat(rawValue: dateFormat) ?? .dashed)
    }

    var backup: BackupSettings {
        BackupSettings(enabled: backupEnabled, folderName: backupFolderName,
                       customLocation: backupCustomPath.map { URL(fileURLWithPath: $0) })
    }

    var options: Options {
        Options(passwords: Prefs.passwords, recursive: recursive, dryRun: true,
                backup: backup, rules: rules)
    }
}

/// Everything a plan carries that affects what applying it does, hashed together: the
/// moves themselves, but also the folder, the recursive flag, every naming rule, and the
/// backup settings. Order of the moves is fixed by sorting so the same plan always hashes
/// the same way regardless of what order the filesystem handed the files back in.
///
/// Takes the plain values that end up stored on `RenamePlan`, not a `NameRules` or
/// `BackupSettings` to reconstruct them from, so that recomputing this from a plan just
/// decoded off disk (`readPlan`, below) hashes exactly the same strings that were hashed
/// when the plan was built, with no detour through a fallback default for a value that
/// happened not to round-trip through an enum's `rawValue`.
func planToken(
    folder: String,
    recursive: Bool,
    casing: String,
    separator: String,
    stripSymbols: Bool,
    stripDiacritics: Bool,
    asciiOnly: Bool,
    dropLeadingArticles: Bool,
    maxLength: Int,
    datePosition: String,
    dateFormat: String,
    backupEnabled: Bool,
    backupFolderName: String,
    backupCustomPath: String?,
    moves: [RenamePlan.Move]
) -> String {
    let settings = [
        folder, String(recursive), casing, separator, String(stripSymbols),
        String(stripDiacritics), String(asciiOnly), String(dropLeadingArticles),
        String(maxLength), datePosition, dateFormat, String(backupEnabled),
        backupFolderName, backupCustomPath ?? "",
    ].joined(separator: "\u{1F}")
    let movesCanonical = moves
        .map { "\($0.from)\u{1F}\($0.to)\u{1F}\($0.bytes)\u{1F}\($0.modified)\u{1F}\($0.status.rawValue)" }
        .sorted()
        .joined(separator: "\u{1E}")
    let canonical = settings + "\u{1E}" + movesCanonical
    return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

/// `planToken`, called with a plan's own stored fields rather than each one spelled out at
/// the call site.
private func planToken(for plan: RenamePlan) -> String {
    planToken(folder: plan.folder, recursive: plan.recursive, casing: plan.casing,
              separator: plan.separator, stripSymbols: plan.stripSymbols,
              stripDiacritics: plan.stripDiacritics, asciiOnly: plan.asciiOnly,
              dropLeadingArticles: plan.dropLeadingArticles, maxLength: plan.maxLength,
              datePosition: plan.datePosition, dateFormat: plan.dateFormat,
              backupEnabled: plan.backupEnabled, backupFolderName: plan.backupFolderName,
              backupCustomPath: plan.backupCustomPath, moves: plan.moves)
}

/// `PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY` overrides the location, for `Tools/mcp-check.sh`
/// alone: a check script needs a scratch folder it controls and can plant fabricated plan
/// files into, not the real directory a copy of PaperShelf on this machine keeps its own
/// pending plans (and its `library.sqlite`) in. Production callers never set it, and get
/// exactly the path this function otherwise resolves to. The long, unmistakable name is
/// deliberate: this is not a general-purpose override like `PAPERSHELF_LIBRARY_PATH`, it is
/// a lever that exists only so a test can stop writing into a real user's Application
/// Support folder, and it should never look like anything a production build could sensibly
/// set.
private func plansDirectory() throws -> URL {
    if let overridden = ProcessInfo.processInfo.environment["PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY"] {
        let folder = URL(fileURLWithPath: overridden, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else {
        throw ToolFailure("there is no Application Support directory to hold a plan")
    }
    let folder = base.appendingPathComponent("PaperShelf", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Just enough of a plan's own JSON to judge its age. Decoded on its own, independent of
/// `RenamePlan`'s full `Codable` conformance, so a future version of this format (an added
/// field, a renamed enum case) does not make an otherwise-current plan unreadable to this
/// sweep merely because `RenamePlan` itself can no longer make sense of every field in it.
/// See `sweepExpiredPlans` for what this is used for.
private struct PlanTimestamp: Decodable {
    let createdAt: Date
}

/// Removes every plan in `plansDirectory()` whose own recorded `createdAt` is older than
/// `RenamePlan.lifetime`, so a proposal nobody ever applies does not sit in Application
/// Support forever. `propose_file_changes` is the only place a plan is written and is
/// called from `writePlan` for exactly that reason: it is the one action that already
/// touches this directory on every call, so a sweep hung off it costs one directory
/// listing on top of work already being done, and needs no timer or run loop of its own in
/// a process that has neither.
///
/// Matches only the exact name `planURL` gives a plan, `pending-plan-*.json`: this same
/// directory also holds `library.sqlite` and its write-ahead log, and a sweep that matched
/// anything looser than the one pattern this feature itself writes would be a disaster
/// instead of a cleanup.
///
/// Expiry is judged from each plan's own `createdAt`, read independently of `RenamePlan`'s
/// full decode (see `PlanTimestamp`), never from the file's modification date: a backup
/// tool or a sync client can rewrite an mtime long after a plan was actually made, which
/// would either hide a plan that is genuinely expired or expire one that is still good.
///
/// A file whose `createdAt` cannot be read at all, whether because the JSON is not valid or
/// because that one field is missing or not a parseable date, is removed outright rather
/// than kept. `readPlan` already refuses anything it cannot decode as a full `RenamePlan`,
/// so such a file can never be applied either way; without a readable timestamp it can also
/// never become "expired" under this scheme, so leaving it alone would mean it sits here
/// forever, which is exactly the litter this sweep exists to stop. This is a narrower bar
/// than failing a full `RenamePlan` decode: a plan written by some future version of this
/// format that added a field or renamed an enum case still has a readable `createdAt` and
/// is judged on its age alone, exactly like any other plan, rather than being deleted
/// merely because this version cannot make sense of everything else in it.
///
/// Never throws, and never lets a single bad entry stop the rest of the sweep: a missing
/// directory, a file that vanishes between the listing and the read, or a permission
/// problem are each swallowed in place, since none of them are `propose_file_changes`'s to
/// report and none of them should turn "here is what would be renamed" into an error about
/// unrelated litter from a previous session.
func sweepExpiredPlans() {
    guard let folder = try? plansDirectory() else { return }
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for url in entries {
        let name = url.lastPathComponent
        guard name.hasPrefix("pending-plan-"), name.hasSuffix(".json") else { continue }
        guard let data = try? Data(contentsOf: url),
              let stamp = try? decoder.decode(PlanTimestamp.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            continue
        }
        guard Date().timeIntervalSince(stamp.createdAt) <= RenamePlan.lifetime else {
            try? FileManager.default.removeItem(at: url)
            continue
        }
    }
}

func planURL(token: String) throws -> URL {
    // A token is hexadecimal by construction; refusing anything else is what keeps a
    // crafted token from naming a file outside this folder.
    guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }) else {
        throw ToolFailure("that is not a token this server handed out. Nothing has been "
            + "moved.")
    }
    return try plansDirectory().appendingPathComponent("pending-plan-\(token).json")
}

func writePlan(_ plan: RenamePlan) throws -> URL {
    // Every proposal a researcher looks at and decides against, or simply lets sit until it
    // expires, would otherwise leave its file behind in Application Support forever, since
    // apply_file_changes is the only other place a plan is ever removed. Swept here, on the
    // one action that already touches this directory, rather than on a timer this process
    // has no run loop to hang one from.
    sweepExpiredPlans()
    let url = try planURL(token: plan.token)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(plan).write(to: url, options: .atomic)
    return url
}

func readPlan(token: String) throws -> RenamePlan {
    let url = try planURL(token: token)
    guard let data = try? Data(contentsOf: url) else {
        throw ToolFailure("no plan with that token; it may have been applied already, or "
            + "expired. Nothing has been moved. Call propose_file_changes again.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let plan = try? decoder.decode(RenamePlan.self, from: data) else {
        throw ToolFailure("that plan could not be read. Nothing has been moved. Call "
            + "propose_file_changes again.")
    }
    guard !plan.isExpired else {
        try? FileManager.default.removeItem(at: url)
        throw ToolFailure("that plan is more than fifteen minutes old. Nothing has been "
            + "moved. Call propose_file_changes again to see what would happen now.")
    }
    // The plan's token, recomputed from exactly what was just decoded. Since every field
    // that feeds the hash round-trips through JSON exactly, this only fails for a plan file
    // damaged or edited after it was written, and it is worth catching: nothing else here
    // checks that a plan's contents still match the token naming it on disk.
    guard planToken(for: plan) == plan.token else {
        try? FileManager.default.removeItem(at: url)
        throw ToolFailure("that plan does not match its own token. Nothing has been "
            + "moved. Call propose_file_changes again.")
    }
    return plan
}

/// Every file in the plan, exactly as it was when the plan was made.
///
/// Whole-plan, not per-file: renaming eleven of twelve files and reporting the twelfth as
/// skipped leaves a folder half-organised, which is harder to reason about than a folder
/// nobody touched. One changed file means propose again.
func verify(_ plan: RenamePlan) throws {
    for move in plan.moves {
        let attributes = try? FileManager.default.attributesOfItem(atPath: move.from)
        guard let attributes else {
            throw ToolFailure("\(move.from) is not where it was when this plan was made. "
                + "Nothing has been moved. Call propose_file_changes again.")
        }
        // `attributesOfItem` answering but missing (or mistyping) one of these two keys is
        // not the same fact as the file having changed, so it gets its own guard and its
        // own sentence rather than being folded into the comparison below through a `-1`
        // that could also, in principle, be a real answer.
        guard let bytes = attributes[.size] as? Int,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            throw ToolFailure("\(move.from)'s size or modification date could not be read. "
                + "Nothing has been moved. Call propose_file_changes again.")
        }
        // Exact, not `abs(a - b) < 1`: storage is now exact epoch seconds, so a real
        // tolerance would only mask that fix, and it would also let a file edited within
        // the same wall-clock second slip past unnoticed.
        guard bytes == move.bytes, modified == move.modified else {
            throw ToolFailure("\(move.from) has changed since this plan was made. Nothing "
                + "has been moved. Call propose_file_changes again.")
        }
        guard !FileManager.default.fileExists(atPath: move.to) else {
            throw ToolFailure("something is already at \(move.to). Nothing has been moved. "
                + "Call propose_file_changes again.")
        }
    }
}

/// Works out what a rename would do, without doing any of it. `process` with `dryRun: true`
/// never touches the filesystem: its move and trash branches both return without writing.
func buildPlan(folder: String, recursive: Bool, rules: NameRules) throws -> RenamePlan {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) else {
        throw ToolFailure("no such folder: \(folder)")
    }
    let backup = Prefs.backup
    let options = Options(passwords: Prefs.passwords, recursive: recursive, dryRun: true,
                          backup: backup, rules: rules)
    // `backup:` is passed explicitly so the scan skips wherever this folder's own backup
    // settings put originals; the default parameter only skips the default folder name, so
    // a folder using a non-default one, or a custom location, would otherwise have its own
    // previously-backed-up originals discovered and offered up for renaming again.
    let jobs = collectJobs(roots: [URL(fileURLWithPath: folder)], recursive: recursive,
                           backup: backup)
    let items = process(jobs: jobs, options: options)
    // A file that vanishes between the scan above and this stat cannot be given an
    // honest size and modification date. Recording zero and the Unix epoch in their place
    // would look exactly like a real reading to whatever later compares against it, so a
    // move whose attributes cannot be read is left out of the plan entirely rather than
    // being shown as a rename that could be approved.
    let moves: [RenamePlan.Move] = items.filter(\.isRenamed).compactMap { item in
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.source.path),
              let bytes = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return RenamePlan.Move(from: item.source.path, to: item.destination.path,
                               bytes: bytes, modified: modified.timeIntervalSince1970,
                               status: item.status)
    }
    let backupFolderName = backup.safeFolderName
    let backupCustomPath = backup.customLocation?.path
    let token = planToken(folder: folder, recursive: recursive, casing: rules.casing.rawValue,
                          separator: rules.separator.rawValue, stripSymbols: rules.stripSymbols,
                          stripDiacritics: rules.stripDiacritics, asciiOnly: rules.asciiOnly,
                          dropLeadingArticles: rules.dropLeadingArticles,
                          maxLength: rules.maxLength, datePosition: rules.datePosition.rawValue,
                          dateFormat: rules.dateFormat.rawValue, backupEnabled: backup.enabled,
                          backupFolderName: backupFolderName, backupCustomPath: backupCustomPath,
                          moves: moves)
    return RenamePlan(
        token: token,
        createdAt: Date(),
        folder: folder,
        recursive: recursive,
        casing: rules.casing.rawValue,
        separator: rules.separator.rawValue,
        stripSymbols: rules.stripSymbols,
        stripDiacritics: rules.stripDiacritics,
        asciiOnly: rules.asciiOnly,
        dropLeadingArticles: rules.dropLeadingArticles,
        maxLength: rules.maxLength,
        datePosition: rules.datePosition.rawValue,
        dateFormat: rules.dateFormat.rawValue,
        backupEnabled: backup.enabled,
        backupFolderName: backupFolderName,
        backupCustomPath: backupCustomPath,
        moves: moves)
}
