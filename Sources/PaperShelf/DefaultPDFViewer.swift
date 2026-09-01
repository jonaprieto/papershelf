import AppKit
import UniformTypeIdentifiers

enum DefaultPDFViewer {
    static func matches(handlerBundleIdentifier: String?, paperShelfBundleIdentifier: String?) -> Bool {
        guard let handlerBundleIdentifier, let paperShelfBundleIdentifier else { return false }
        return handlerBundleIdentifier == paperShelfBundleIdentifier
    }

    @MainActor
    static func isPaperShelfDefault() -> Bool {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: .pdf)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return matches(handlerBundleIdentifier: handler,
                       paperShelfBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    @MainActor
    static func makePaperShelfDefault() async -> Error? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                      toOpen: .pdf) { error in
                continuation.resume(returning: error)
            }
        }
    }
}
