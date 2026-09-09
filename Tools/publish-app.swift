import Foundation

func failure(_ message: String) -> NSError {
    NSError(domain: "PaperShelfBuild", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// Installation and local rebuilds replace the app only after a complete copy verifies.
func publish() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--record") else {
        throw failure("Usage: publish-app.swift source.app destination.app [--record path.json]")
    }
    let files = FileManager.default
    let source = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let destination = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let temporary = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: destination, create: true)
    defer { try? files.removeItem(at: temporary) }
    let staged = temporary.appendingPathComponent("PaperShelf.app")
    try files.copyItem(at: source, to: staged)

    let data = try Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    guard info?["CFBundleIdentifier"] as? String == "com.jonaprieto.pdfhammer",
          let id = info?["PaperShelfBuildID"] as? String, UUID(uuidString: id) != nil,
          let version = info?["CFBundleShortVersionString"] as? String,
          let builtAt = info?["PaperShelfBuiltAt"] as? String,
          ISO8601DateFormatter().date(from: builtAt) != nil,
          let channel = info?["PaperShelfBuildChannel"] as? String,
          ["development", "release"].contains(channel) else {
        throw failure("The staged app has incomplete build metadata")
    }
    let verify = Process()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    verify.arguments = ["--verify", "--strict", "--deep", staged.path]
    try verify.run()
    verify.waitUntilExit()
    guard verify.terminationStatus == 0 else { throw failure("The staged app signature did not verify") }

    if files.fileExists(atPath: destination.path) {
        _ = try files.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
    } else {
        try files.moveItem(at: staged, to: destination)
    }

    if arguments.count == 4, channel == "development" {
        // A failed cache write must not turn a valid app build into a failed build.
        do {
            let recordURL = URL(fileURLWithPath: arguments[3])
            try files.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let record: [String: String] = ["bundlePath": destination.path, "buildID": id,
                                          "version": version, "builtAt": builtAt]
            try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
                .write(to: recordURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Local build notice could not be saved: \(error.localizedDescription)\n".utf8))
        }
    }
}

do { try publish() }
catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
