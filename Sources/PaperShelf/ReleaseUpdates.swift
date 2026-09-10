import Foundation
import Observation
import PaperShelfCore

struct StableVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ tag: String) {
        let parts = (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") &&
                  $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// Validate cached responses as strictly as network responses before exposing a link.
struct PublishedRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let state: String
        let size: Int
    }
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var version: StableVersion? { StableVersion(tag_name) }
    var isValid: Bool {
        guard let version, !draft, !prerelease,
              let url = URLComponents(url: html_url, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == "github.com", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/jonaprieto/papershelf/releases/tag/\(tag_name)" else { return false }
        return assets.contains { $0.name == "PaperShelf-\(version).dmg" && $0.state == "uploaded" && $0.size > 0 }
    }
}

@Observable
@MainActor
final class ReleaseUpdates {
    static let shared = ReleaseUpdates()
    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/jonaprieto/papershelf/releases/latest")!

    let running: AppBuild
    private(set) var release: PublishedRelease?
    private(set) var lastAttempt: Date?
    private(set) var lastSuccess: Date?
    private(set) var retryAfter: Date?
    private(set) var checking = false
    private(set) var failure: String?
    private(set) var dismissedVersion: String?
    private let defaults: UserDefaults
    private let fetch: HTTPFetch
    private let now: () -> Date

    init(running: AppBuild = .current, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping HTTPFetch = { request in
             let session = URLSession(configuration: .ephemeral)
             defer { session.finishTasksAndInvalidate() }
             return try await session.data(for: request)
         }) {
        self.running = running
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        lastAttempt = defaults.object(forKey: "updates.lastAttempt") as? Date
        retryAfter = defaults.object(forKey: "updates.retryAfter") as? Date
        dismissedVersion = defaults.string(forKey: "updates.dismissedVersion")
        failure = defaults.string(forKey: "updates.failure")
        if let data = defaults.data(forKey: "updates.release"),
           let cached = try? JSONDecoder().decode(PublishedRelease.self, from: data), cached.isValid {
            release = cached
            lastSuccess = defaults.object(forKey: "updates.lastSuccess") as? Date
        }
    }

    var statusText: String {
        if checking { return "Checking for updates..." }
        if let failure { return failure }
        guard let release, let latest = release.version, lastSuccess != nil else { return "Releases have not been checked." }
        guard let current = StableVersion(running.version) else { return "The running version could not be compared." }
        if latest > current { return "A newer release is available." }
        if running.channel == .development { return "Latest published release checked." }
        return latest == current ? "Your release is up to date." : "Your version is newer than the latest published release."
    }

    var newerRelease: PublishedRelease? {
        guard let current = StableVersion(running.version), let release,
              let available = release.version, available > current else { return nil }
        return release
    }

    var showsBadge: Bool {
        guard let newerRelease else { return false }
        return newerRelease.version?.description != dismissedVersion
    }

    func dismissRelease() {
        dismissedVersion = newerRelease?.version?.description
        defaults.set(dismissedVersion, forKey: "updates.dismissedVersion")
    }

    func check(manual: Bool, automaticChecks: Bool) async {
        guard !checking else { return }
        let started = now()
        if let retryAfter, retryAfter > started {
            if manual { failure = "GitHub asked us to wait before checking again." }
            return
        }
        guard manual || (automaticChecks &&
            (lastAttempt.map { started.timeIntervalSince($0) >= 86_400 } ?? true)) else { return }
        checking = true
        failure = nil
        lastAttempt = started
        defaults.set(started, forKey: "updates.lastAttempt")
        defer { checking = false }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PaperShelf/\(running.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
            guard http.statusCode == 200 else {
                let failures = min(6, defaults.integer(forKey: "updates.rateLimitFailures") + 1)
                if http.statusCode == 403 || http.statusCode == 429 {
                    defaults.set(failures, forKey: "updates.rateLimitFailures")
                    retryAfter = now().addingTimeInterval(60 * pow(2, Double(failures - 1)))
                }
                if let delay = http.value(forHTTPHeaderField: "Retry-After") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    let date = Double(delay).flatMap { $0.isFinite && $0 >= 0 ? now().addingTimeInterval($0) : nil }
                        ?? formatter.date(from: delay)
                    if let date { retryAfter = max(retryAfter ?? date, date) }
                }
                if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
                   let value = http.value(forHTTPHeaderField: "X-RateLimit-Reset"),
                   let seconds = Double(value), seconds.isFinite {
                    let date = Date(timeIntervalSince1970: seconds)
                    retryAfter = max(retryAfter ?? date, date)
                }
                defaults.set(retryAfter, forKey: "updates.retryAfter")
                throw CheckError.http(http.statusCode)
            }
            let result = try JSONDecoder().decode(PublishedRelease.self, from: data)
            guard result.isValid else { throw CheckError.invalidRelease }
            release = result
            lastSuccess = now()
            retryAfter = nil
            defaults.set(data, forKey: "updates.release")
            defaults.set(lastSuccess, forKey: "updates.lastSuccess")
            defaults.removeObject(forKey: "updates.retryAfter")
            defaults.removeObject(forKey: "updates.failure")
            defaults.removeObject(forKey: "updates.rateLimitFailures")
        } catch {
            failure = "Could not verify the latest release. \(error.localizedDescription)"
            defaults.set(failure, forKey: "updates.failure")
        }
    }

    private enum CheckError: LocalizedError {
        case invalidResponse, invalidRelease, http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "GitHub returned an unreadable response."
            case .invalidRelease: return "GitHub did not return a stable PaperShelf release with a downloadable disk image."
            case .http(let status): return "GitHub returned HTTP \(status)."
            }
        }
    }
}
