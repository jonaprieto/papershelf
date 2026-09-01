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
        let bytes: Int
        let modified: Date
    }

    /// The plan's own hash, which is also its name on disk. A token cannot be pointed at a
    /// different plan and a plan cannot drift out from under a token issued for it.
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

/// The moves, hashed. Order is fixed by sorting so the same plan always hashes the same
/// way regardless of what order the filesystem handed the files back in.
func planToken(_ moves: [RenamePlan.Move]) -> String {
    let canonical = moves
        .map { "\($0.from)\u{1F}\($0.to)\u{1F}\($0.bytes)\u{1F}\($0.modified.timeIntervalSince1970)" }
        .sorted()
        .joined(separator: "\u{1E}")
    return SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
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
    return plan
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
    let jobs = collectJobs(roots: [URL(fileURLWithPath: folder)], recursive: recursive)
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
                               bytes: bytes, modified: modified)
    }
    return RenamePlan(
        token: planToken(moves),
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
        backupFolderName: backup.safeFolderName,
        backupCustomPath: backup.customLocation?.path,
        moves: moves)
}
