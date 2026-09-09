import Foundation
import PaperShelfCore

/// Captured before a local rebuild can replace the bundle beneath the running process.
struct AppBuild: Equatable, Sendable {
    enum Channel: String, Codable, Sendable {
        case development, release
    }

    static let current = AppBuild(info: Bundle.main.infoDictionary ?? [:], at: Bundle.main.bundleURL)

    let version: String
    let build: String
    let revision: String?
    let channel: Channel
    let id: UUID?
    let builtAt: Date?
    let bundleURL: URL

    init(info: [String: Any], at bundleURL: URL) {
        version = info["CFBundleShortVersionString"] as? String ?? paperShelfVersion
        build = info["CFBundleVersion"] as? String ?? "unknown"
        revision = info["PaperShelfGitCommit"] as? String
        channel = (info["PaperShelfBuildChannel"] as? String).flatMap(Channel.init) ?? .development
        id = (info["PaperShelfBuildID"] as? String).flatMap(UUID.init(uuidString:))
        builtAt = (info["PaperShelfBuiltAt"] as? String).flatMap(ISO8601DateFormatter().date(from:))
        self.bundleURL = bundleURL.standardizedFileURL
    }

    var description: String {
        let channelName = channel == .development ? "development" : "release"
        return "PaperShelf \(version), build \(build), \(channelName), commit \(revision ?? "unrecorded")"
    }
}
