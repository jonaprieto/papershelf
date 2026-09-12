import Foundation
import Darwin

/// Rules travel with the directory walk, so each ignore file is read only once.
struct GitIgnore {
    private struct Rule {
        let base: String
        let pattern: [String]
        let anchored: Bool
        let directoryOnly: Bool
        let negated: Bool

        /// `name` is the entry's last path component, which the caller already has.
        ///
        /// An unanchored rule asks about that component and nothing else, and most rules
        /// are unanchored. Splitting the whole relative path to reach it, for every rule
        /// in scope and every entry in the walk, cost four fifths of a source scan: on a
        /// tree of seventy thousand entries it took `collectJobs` from 270ms to 1.1s.
        func matches(_ fullPath: String, name: String, directory: Bool) -> Bool {
            guard !directoryOnly || directory, fullPath.hasPrefix(base) else { return false }
            if !anchored {
                return fnmatch(pattern[0], name, 0) == 0
            }
            let path = String(fullPath.dropFirst(base.count)).components(separatedBy: "/")
            // Component matching keeps '*' out of subdirectories; '**' alone may cross them.
            var reachable = Set([0])
            for (offset, component) in pattern.enumerated() {
                var next = Set<Int>()
                for index in reachable {
                    if component == "**" {
                        let start = offset == pattern.count - 1 ? index + 1 : index
                        if start <= path.count { next.formUnion(start...path.count) }
                    } else if index < path.count, fnmatch(component, path[index], 0) == 0 {
                        next.insert(index + 1)
                    }
                }
                reachable = next
            }
            return reachable.contains(path.count)
        }
    }

    private var rules: [Rule] = []

    func excludes(_ url: URL, directory: Bool) -> Bool {
        guard !rules.isEmpty else { return false }
        // Directory reads can return /private/var for a source selected through /var.
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        return rules.last(where: { $0.matches(path, name: name, directory: directory) })
            .map { !$0.negated } ?? false
    }

    mutating func read(in directory: URL) {
        let file = directory.appendingPathComponent(".gitignore")
        // Git does not follow a symbolic link used as an ignore file.
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if line.last == "\r" { line.removeLast() }
            while line.last == " " {
                let escapes = line.dropLast().reversed().prefix(while: { $0 == "\\" }).count
                if escapes % 2 == 1 { break }
                line.removeLast()
            }
            guard !line.isEmpty, line.first != "#" else { continue }
            let negated = line.first == "!"
            if negated { line.removeFirst() }
            let directoryOnly = line.last == "/"
            if directoryOnly { line.removeLast() }
            let anchored = line.contains("/")
            if line.first == "/" { line.removeFirst() }
            guard !line.isEmpty else { continue }
            let path = directory.standardizedFileURL.path
            let base = path == "/" ? "/" : path + "/"
            rules.append(Rule(base: base, pattern: line.components(separatedBy: "/"),
                              anchored: anchored, directoryOnly: directoryOnly, negated: negated))
        }
    }

    /// Selecting a subfolder must not bypass exclusions in its parents. Stop at the
    /// repository boundary, but also support source folders with no Git repository.
    static func inherited(by selection: URL) -> GitIgnore? {
        if selection.path == "/" || FileManager.default.fileExists(
            atPath: selection.appendingPathComponent(".git").path) { return GitIgnore() }
        var parents: [URL] = []
        var parent = selection.deletingLastPathComponent()
        while true {
            parents.append(parent)
            if parent.path == "/" || FileManager.default.fileExists(
                atPath: parent.appendingPathComponent(".git").path) { break }
            parent.deleteLastPathComponent()
        }
        var ignore = GitIgnore()
        for directory in parents.reversed() {
            guard !ignore.excludes(directory, directory: true) else { return nil }
            ignore.read(in: directory)
        }
        return ignore
    }
}
