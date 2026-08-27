import Foundation

/// The revision this server speaks natively, and the older ones it still answers.
///
/// 2026-07-28 removed the initialize handshake and made every request carry its own
/// protocol version in `_meta`, but the clients people actually have installed still open
/// with `initialize`. Both eras are answered from the same handlers: a modern result is a
/// legacy result with three extra fields, and a legacy client ignores fields it does not
/// know.
enum Revision {
    static let current = "2026-07-28"
    static let supported = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
}

enum RPCError {
    /// JSON-RPC's own codes. -32020 upwards is the range the MCP specification reserved
    /// for itself in this revision; -32602 is plain invalid params.
    static let invalidParams = -32602
    static let unsupportedProtocolVersion = -32022
    static let internalError = -32603
}

struct Tool {
    let name: String
    let title: String
    let description: String
    let inputSchema: [String: Any]
    let run: ([String: Any]) throws -> ToolOutput
}

/// What a tool gives back: text for the model to read, and optionally the same thing as
/// data. The specification asks for both, since a client that validates against an output
/// schema wants the structure and a model just wants to read.
struct ToolOutput {
    var text: String
    var structured: Any?
    var isError: Bool = false

    static func failure(_ message: String) -> ToolOutput {
        ToolOutput(text: message, structured: nil, isError: true)
    }
}

/// A tool that raises this is reporting something the model can fix by calling again with
/// different arguments, which the specification says to return as a result with isError
/// rather than as a protocol-level error.
struct ToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
        throw ToolFailure("'\(key)' is required and must be a non-empty string")
    }
    return value
}

func optionalBool(_ arguments: [String: Any], _ key: String, default fallback: Bool) -> Bool {
    arguments[key] as? Bool ?? fallback
}
