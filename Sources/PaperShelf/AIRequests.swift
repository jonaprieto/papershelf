import Foundation

/// One transport makes disabling AI apply to every caller, including already open sheets.
@MainActor
enum AIRequests {
    static var session = URLSession(configuration: .ephemeral)

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard Prefs.shared.aiEnabled else { throw AIError.disabled }
        return try await session.data(for: request)
    }

    static func cancelAll() {
        session.invalidateAndCancel()
        session = URLSession(configuration: .ephemeral)
    }
}
