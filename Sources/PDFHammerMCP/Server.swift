import Foundation

/// Newline-delimited JSON-RPC over stdin and stdout, which is what the stdio transport is.
///
/// Nothing but JSON-RPC ever goes to stdout: the specification is explicit that a stdio
/// server logs to stderr, and a stray print here corrupts the stream for the client.
struct Server {
    let tools: [Tool]
    let name: String
    let version: String
    let instructions: String

    private var byName: [String: Tool] { Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }) }

    func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard !line.isEmpty else { continue }
                if let reply = respond(to: Data(line)) {
                    output.write(reply)
                    output.write(Data([0x0A]))
                }
            }
        }
    }

    /// Nil when the message was a notification, which by JSON-RPC gets no reply at all.
    func respond(to line: Data) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let method = message["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": NSNull(),
                           "error": ["code": -32700, "message": "not JSON-RPC"]])
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        // A modern client states its version on every request. An older one negotiated it
        // once in initialize, so its absence here is not an error.
        if let meta = params["_meta"] as? [String: Any],
           let asked = meta["io.modelcontextprotocol/protocolVersion"] as? String,
           !Revision.supported.contains(asked) {
            return encode(["jsonrpc": "2.0", "id": id,
                           "error": ["code": RPCError.unsupportedProtocolVersion,
                                     "message": "unsupported protocol version: \(asked)",
                                     "data": ["supportedVersions": Revision.supported]]])
        }

        switch method {
        case "server/discover":
            return encode(["jsonrpc": "2.0", "id": id, "result": cacheable([
                "resultType": "complete",
                "supportedVersions": Revision.supported,
                "capabilities": ["tools": [String: Any]()],
                "instructions": instructions,
                "_meta": ["io.modelcontextprotocol/serverInfo": ["name": name, "version": version]],
            ], seconds: 3600)])

        case "initialize":
            // The pre-2026 handshake. Answer in the version the client asked for when it
            // is one this server knows, which is what negotiation means here.
            let asked = params["protocolVersion"] as? String
            let agreed = Revision.supported.contains(asked ?? "") ? asked! : "2025-06-18"
            return encode(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": agreed,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ]])

        case "tools/list":
            let listed = tools.map { tool -> [String: Any] in
                ["name": tool.name, "title": tool.title, "description": tool.description,
                 "inputSchema": tool.inputSchema]
            }
            return encode(["jsonrpc": "2.0", "id": id,
                           "result": cacheable(["resultType": "complete", "tools": listed],
                                               seconds: 300)])

        case "tools/call":
            guard let called = params["name"] as? String, let tool = byName[called] else {
                return encode(["jsonrpc": "2.0", "id": id,
                               "error": ["code": RPCError.invalidParams,
                                         "message": "Unknown tool: \(params["name"] ?? "")"]])
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let outcome: ToolOutput
            do {
                outcome = try tool.run(arguments)
            } catch let failure as ToolFailure {
                outcome = .failure(failure.message)
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            var result: [String: Any] = [
                "resultType": "complete",
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError,
            ]
            if let structured = outcome.structured { result["structuredContent"] = structured }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])

        // Declared unsupported rather than left to time out.
        case "resources/list", "prompts/list":
            let key = method.hasPrefix("resources") ? "resources" : "prompts"
            return encode(["jsonrpc": "2.0", "id": id,
                           "result": cacheable(["resultType": "complete", key: [Any]()],
                                               seconds: 3600)])

        default:
            return encode(["jsonrpc": "2.0", "id": id,
                           "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    /// Every list result in this revision has to say how long it may be cached for.
    private func cacheable(_ result: [String: Any], seconds: Int) -> [String: Any] {
        var out = result
        out["ttlMs"] = seconds * 1000
        out["cacheScope"] = "private"
        return out
    }

    private func encode(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#.utf8)
    }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
