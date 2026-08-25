import Foundation

/// The last run, kept so the window can show something the instant it opens.
///
/// What is stored is a preview, not a claim about the present: files move and change
/// between launches. It is shown immediately and replaced by a real scan as soon as one
/// finishes, which is why the fingerprint is recorded alongside it.
public struct RunCache: Codable, Sendable {
    public let fingerprint: String
    public let savedAt: Date
    public let items: [Item]

    public init(fingerprint: String, savedAt: Date = Date(), items: [Item]) {
        self.fingerprint = fingerprint
        self.savedAt = savedAt
        self.items = items
    }
}

/// Where the cache lives. Application Support rather than a preference, because this is
/// data rather than a setting, and it can be large.
public func runCacheURL(named name: String = "last-run.json") -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first else { return nil }
    let folder = base.appendingPathComponent("PDF Hammer", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
}

/// Writes the cache, quietly. A failure here costs a slower launch, nothing more, so it
/// is not worth interrupting anyone over.
public func saveRunCache(_ cache: RunCache) {
    guard let url = runCacheURL() else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(cache) else { return }
    try? data.write(to: url, options: .atomic)
}

/// Reads the cache back, if it matches the sources being asked about.
public func loadRunCache(matching fingerprint: String) -> RunCache? {
    guard let url = runCacheURL(), let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let cache = try? decoder.decode(RunCache.self, from: data),
          cache.fingerprint == fingerprint else { return nil }
    return cache
}

public func clearRunCache() {
    guard let url = runCacheURL() else { return }
    try? FileManager.default.removeItem(at: url)
}
