import Foundation
import PaperShelfCore

/// A small append-only log that survives an app crash. It records app events, not PDF
/// text, paths, passwords or API keys, so it is safe to attach when reporting a failure.
final class AppDiagnostics {
    static let shared = AppDiagnostics()

    let url: URL
    private let lock = NSLock()

    private init() {
        url = supportDirectory()?.appendingPathComponent("diagnostics.log")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "PaperShelf-diagnostics.log")
    }

    func start() {
        record("launch version=\(paperShelfVersion) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func record(_ message: String) {
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        append("\(ISO8601DateFormatter().string(from: Date())) \(clean)\n")
    }

    /// Objective-C exceptions are rare in SwiftUI, but if one escapes this preserves the
    /// last useful line before the process is terminated. macOS still owns full crash
    /// reports for fatal signals and memory faults.
    static func uncaughtException(_ exception: NSException) {
        shared.record("uncaught exception name=\(exception.name.rawValue) reason=\(exception.reason ?? "unknown")")
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
        try? file.synchronize()
        try? file.close()
    }
}
