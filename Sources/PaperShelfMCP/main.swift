import Foundation
import PaperShelfCore

if CommandLine.arguments.contains("--version") {
    print(paperShelfVersion)
    exit(0)
}

let server = Server(
    tools: folderTools + libraryTools + writeTools,
    name: "papershelf",
    version: paperShelfVersion,
    instructions: "Read, search and organise a local PDF library. Start with "
        + "list_documents with no arguments, which reports what the library holds; "
        + "search_documents with no folder searches all of it and quotes the passages it "
        + "matched with their page numbers. Every result carries a document_id that "
        + "read_document, read_page, list_highlights, add_to_project and set_tags all "
        + "accept, so nothing needs a file path. Paths, where they appear, are absolute "
        + "paths on this machine, and nothing leaves it."
)

note("papershelf \(paperShelfVersion) ready, speaking \(Revision.current) and the initialize handshake")
server.run()
