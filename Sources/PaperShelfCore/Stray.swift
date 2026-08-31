import Foundation

/// Documents the library is holding that no source accounts for any more.
///
/// Two ways a document becomes one. Its folder stopped being a source, so nothing watches
/// where it lives; or its file was deleted out of a folder that is still watched. Both
/// leave a row that goes on answering searches, filling reading projects and counting on
/// a shelf, for a paper the app has no reason to know about.
///
/// A path *supports* a document when it is under one of `sources` and the file is there.
/// One supporting path is enough: a book filed in a watched folder and an unwatched one
/// is still a book this library is looking after.
///
/// The exception is the one that matters. A path under a source whose file is missing
/// *and* whose folder is missing too also supports the document, because that is what an
/// unplugged external drive looks like, and forgetting a library that is one cable away
/// would throw out its tags, notes and reading positions. The cost is that a watched
/// folder deleted outright leaves rows behind; that is the right way round, since a
/// tidy-up that forgets too little can be run again.
///
/// `exists` is passed in rather than called here, so the rule can be reasoned about and
/// tested without a disk.
public func strayDocuments(_ locations: [String: [String]],
                           sources: [String],
                           exists: (String) -> Bool) -> [String] {
    let roots = sources.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }

    func covered(_ path: String) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func supports(_ path: String) -> Bool {
        guard covered(path) else { return false }
        if exists(path) { return true }
        // Under a source, but not there. Gone from a folder that is still present; or on
        // a volume that is not mounted, in which case the folder is missing too.
        return !exists((path as NSString).deletingLastPathComponent)
    }

    return locations.compactMap { id, paths in
        paths.contains(where: supports) ? nil : id
    }
    .sorted()
}
