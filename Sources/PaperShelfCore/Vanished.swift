import Foundation

/// Which documents no longer exist anywhere the library knows to look.
///
/// The store records where a document has lived; only the filesystem can say whether any
/// of those places is still there. `exists` is passed in rather than called here so this
/// rule can be reasoned about, and tested, without a disk.
///
/// Two conditions, and the second is the one that matters. A document is forgotten when
/// every path it is known at is missing AND at least one of those paths still has a
/// folder to be missing from. Without that second half, unplugging an external drive
/// would make every document on it look deleted, and one tidy-up would throw away the
/// tags, notes and reading positions of a library that is merely not mounted.
///
/// The same caution costs something: a folder deleted outright, with everything in it,
/// leaves documents this will not touch. That is the right way round. A tidy-up that
/// forgets too little is a tidy-up you can run again; one that forgets too much is work
/// nobody can type back in.
public func vanishedDocuments(_ locations: [String: [String]],
                              exists: (String) -> Bool) -> [String] {
    locations.compactMap { id, paths in
        guard !paths.isEmpty else { return nil }
        guard paths.allSatisfy({ !exists($0) }) else { return nil }
        let anyFolderSurvives = paths.contains { path in
            exists((path as NSString).deletingLastPathComponent)
        }
        return anyFolderSurvives ? id : nil
    }
    .sorted()
}
