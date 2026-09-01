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
        .map { "\($0.from)\u{1F}\($0.to)\u{1F}\($0.bytes)\u{1F}\($0.modified)" }
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

private func plansDirectory() throws -> URL {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else {
        throw ToolFailure("there is no Application Support directory to hold a plan")
    }
    let folder = base.appendingPathComponent("PaperShelf", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

func planURL(token: String) throws -> URL {
    // A token is hexadecimal by construction; refusing anything else is what keeps a
    // crafted token from naming a file outside this folder.
    guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }) else {
        throw ToolFailure("that is not a token this server handed out")
    }
    return try plansDirectory().appendingPathComponent("pending-plan-\(token).json")
}

func writePlan(_ plan: RenamePlan) throws -> URL {
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
            + "expired. Call propose_file_changes again.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let plan = try? decoder.decode(RenamePlan.self, from: data) else {
        throw ToolFailure("that plan could not be read; call propose_file_changes again")
    }
    guard !plan.isExpired else {
        try? FileManager.default.removeItem(at: url)
        throw ToolFailure("that plan is more than fifteen minutes old; call "
            + "propose_file_changes again to see what would happen now")
    }
    // The plan's token, recomputed from exactly what was just decoded. Since every field
    // that feeds the hash round-trips through JSON exactly, this only fails for a plan file
    // damaged or edited after it was written, and it is worth catching: nothing else here
    // checks that a plan's contents still match the token naming it on disk.
    guard planToken(for: plan) == plan.token else {
        try? FileManager.default.removeItem(at: url)
        throw ToolFailure("that plan does not match its own token; call "
            + "propose_file_changes again")
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
        let bytes = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
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
                               bytes: bytes, modified: modified.timeIntervalSince1970)
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
