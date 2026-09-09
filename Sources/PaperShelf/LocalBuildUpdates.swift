import Foundation
import Observation

extension AppBuild {
    /// Read the filesystem directly because Bundle caches metadata across replacements.
    static func completed(at url: URL) -> AppBuild? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.jonaprieto.pdfhammer",
              let version = info["CFBundleShortVersionString"] as? String, StableVersion(version) != nil,
              let channel = info["PaperShelfBuildChannel"] as? String, Channel(rawValue: channel) != nil else { return nil }
        let build = AppBuild(info: info, at: url)
        let files = FileManager.default
        guard build.id != nil, build.builtAt != nil,
              files.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/PaperShelf").path),
              files.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/papershelf-mcp").path),
              files.fileExists(atPath: url.appendingPathComponent("Contents/_CodeSignature/CodeResources").path) else { return nil }
        return build
    }
}

@Observable
@MainActor
final class LocalBuildUpdates {
    static let shared = LocalBuildUpdates()
    nonisolated static let recordURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/PaperShelf/development-build.json")

    let running: AppBuild
    private(set) var available: AppBuild?
    private(set) var dismissedID: UUID?
    private var checking = false
    private let defaults: UserDefaults
    private let recordURL: URL

    init(running: AppBuild = .current, defaults: UserDefaults = .standard, recordURL: URL = LocalBuildUpdates.recordURL) {
        self.running = running
        self.defaults = defaults
        self.recordURL = recordURL
        dismissedID = defaults.string(forKey: "updates.dismissedBuild").flatMap(UUID.init(uuidString:))
    }

    var showsBadge: Bool { available.map { $0.id != dismissedID } ?? false }

    func dismissBuild() {
        dismissedID = available?.id
        defaults.set(dismissedID?.uuidString, forKey: "updates.dismissedBuild")
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let running = running
        let recordURL = recordURL
        // A recorded checkout can be on a sleeping external disk. Reading it must not
        // stall the first frame when somebody returns to a paper.
        available = await Task.detached(priority: .utility) {
            Self.find(running: running, recordURL: recordURL)
        }.value
    }

    nonisolated static func find(running: AppBuild, recordURL: URL) -> AppBuild? {
        guard let runningID = running.id else { return nil }
        let replacement = AppBuild.completed(at: running.bundleURL)
        if let replacement, replacement.id != runningID { return replacement }
        guard running.channel == .development, let started = running.builtAt,
              let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.bundlePath.hasPrefix("/"), record.buildID != runningID,
              let bundle = AppBuild.completed(at: URL(fileURLWithPath: record.bundlePath)),
              bundle.channel == .development, bundle.id == record.buildID,
              bundle.version == record.version,
              let date = ISO8601DateFormatter().date(from: record.builtAt),
              bundle.builtAt == date, date >= started else { return nil }
        return bundle
    }

    private struct Record: Decodable {
        let bundlePath: String
        let buildID: UUID
        let version: String
        let builtAt: String
    }
}
