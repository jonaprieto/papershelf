import Foundation

let server = Server(
    tools: folderTools + libraryTools + writeTools,
    name: "papershelf",
    version: "1.1.0",
    instructions: "Read and search a local PDF library. Paths are absolute paths on this "
        + "machine. Start with list_documents on a folder the user names, then "
        + "read_document to get a document's text as Markdown."
)

note("papershelf MCP server ready, speaking \(Revision.current) and the initialize handshake")
server.run()
