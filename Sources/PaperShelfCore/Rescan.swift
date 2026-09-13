import Foundation

/// Where the watcher saw something change under a source.
///
/// A file or a folder, because they are asked about differently: a file is one job that
/// is there or is not, and a folder carries everything under it, since FSEvents reports a
/// folder moved in or renamed rather than every file inside it.
public enum ChangedPlace: Sendable, Hashable {
    case file(URL)
    case folder(URL)

    public var url: URL {
        switch self {
        case .file(let url), .folder(let url): return url
        }
    }
}

/// How many places a burst may name before a rescan stops being worth scoping.
///
/// Every scoped root works out its own inherited ignore rules, climbing to the top of its
/// repository to do it, so ten thousand of them (an archive unpacked into a source) costs
/// more than the one walk it was meant to replace.
public let scopedRescanLimit = 256

/// The jobs a plan has once the places that changed have been walked again.
///
/// Everything from the last scan that sits outside what changed is kept as it was. Inside
/// what changed, the fresh walk is the whole truth: a file it did not find is gone, and a
/// file it found that the plan did not have has arrived. This is what lets the watcher walk
/// a folder somebody saved into rather than the whole of a source that is also a working
/// tree, where a single build used to cost a full walk of every folder in it.
///
/// A walk rooted at a changed place records that place as each job's root, which is not the
/// source the job belongs to: the tree and every relative path are built from `root`. So
/// each job found is given back the source that holds it.
///
/// The result is in the order `collectJobs` returns, by path, so a file that arrives lands
/// where a full scan would have put it. Sorted on the key rather than on `file.path`: a walk
/// rooted at a file spells it `/var/...` while a walk of its folder spells it
/// `/private/var/...`, and a sort on those strings put a file that had just arrived last.
public func mergeRescan(previous: [Job], found: [Job], changed: [ChangedPlace],
                        roots: [URL]) -> [Job] {
    let files = Set(changed.compactMap { place -> String? in
        guard case .file(let url) = place else { return nil }
        return Item.identity(of: url)
    })
    let folders = changed.compactMap { place -> String? in
        guard case .folder(let url) = place else { return nil }
        return Item.identity(of: url) + "/"
    }
    func touched(_ key: String) -> Bool {
        files.contains(key) || folders.contains { key.hasPrefix($0) }
    }

    let sources = roots.map { (url: $0, prefix: Item.identity(of: $0) + "/") }
        .sorted { $0.prefix.count > $1.prefix.count }
    var merged: [String: Job] = [:]
    for job in previous where !touched(job.key) { merged[job.key] = job }
    for job in found {
        let owner = sources.first { job.key.hasPrefix($0.prefix) }?.url ?? job.root
        merged[job.key] = Job(root: owner, file: job.file)
    }
    return merged.values.sorted { $0.key < $1.key }
}
