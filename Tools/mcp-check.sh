#!/usr/bin/env bash
# Drive the MCP server over stdio and check every answer, both protocol eras.
# Usage: Tools/mcp-check.sh [path-to-binary]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-$(swift build --show-bin-path)/PaperShelfMCP}"
[[ -x "$BIN" ]] || { echo "no binary at $BIN; run 'swift build' first" >&2; exit 1; }

FOLDER="$(mktemp -d)"
trap 'rm -rf "$FOLDER"' EXIT

# A library-shaped scratch database, built straight with sqlite3 rather than through the app,
# so this script owns every row in it and does not depend on PaperShelf having been run on
# this machine. The schema mirrors Library.swift's own schemaV1 (documents, locations, tags,
# document_tags, projects, project_members with its section, notes, extracted_text/_fts) plus
# schemaV7's format column on extracted_text and its PRAGMA user_version; a change to either
# is expected to need a matching change here.
LIBRARY_DB="$FOLDER/library.sqlite"

# A real, valid one-page PDF whose only text is the word "hello", written to the same
# folder the trap above already cleans up. This backs doc-3 below: the one document in the
# fixture that has no extracted_text row, so reading it for the first time has to open this
# file rather than the cache, exercising storedOrExtracted's write-back for real.
HELLO_PDF="$FOLDER/hello.pdf"
base64 -d > "$HELLO_PDF" <<'PDF'
JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2Jq
CjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2Jq
CjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAg
MjAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAw
IFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAzNiA+PgpzdHJlYW0KQlQgL0YxIDEyIFRm
IDIwIDEwMCBUZCAoaGVsbG8pIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNSAwIG9iago8PCAvVHlw
ZSAvRm9udCAvU3VidHlwZSAvVHlwZTEgL0Jhc2VGb250IC9IZWx2ZXRpY2EgPj4KZW5kb2JqCnhy
ZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4
IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI0MSAwMDAwMCBuIAowMDAwMDAw
MzI3IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgNiAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYK
Mzk3CiUlRU9GCg==
PDF

# A second copy of the same file, at a different path: `locations.path` is a primary key, so
# two documents can never share one location row, and doc-6 below (built for the bibliography
# shortfall check) needs a real, distinct, openable PDF of its own rather than doc-3's.
HELLO2_PDF="$FOLDER/hello2.pdf"
cp "$HELLO_PDF" "$HELLO2_PDF"

# Unquoted (unlike a plain schema-only heredoc) so $HELLO_PDF below expands; nothing else in
# this block uses a shell metacharacter, so that is the only effect of the change.
sqlite3 "$LIBRARY_DB" <<SQL
CREATE TABLE documents (
    id             TEXT PRIMARY KEY,
    first_seen_at  TEXT NOT NULL,
    last_seen_at   TEXT NOT NULL,
    content_hash   TEXT,
    byte_count     INTEGER,
    page_count     INTEGER,
    title          TEXT,
    author         TEXT,
    document_info  TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE locations (
    path           TEXT PRIMARY KEY,
    document_id    TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    first_seen_at  TEXT NOT NULL,
    last_seen_at   TEXT NOT NULL
);
CREATE TABLE tags (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE
);
CREATE TABLE document_tags (
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    tag_id      INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (document_id, tag_id)
);
CREATE TABLE projects (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE project_members (
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    added_at    TEXT NOT NULL,
    -- Added by schemaV4: which part of the reading list a document is filed under.
    section     TEXT,
    PRIMARY KEY (project_id, document_id)
);
CREATE TABLE notes (
    id          INTEGER PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    body        TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
CREATE TABLE extracted_text (
    document_id  TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
    markdown     TEXT NOT NULL,
    extracted_at TEXT NOT NULL,
    format       TEXT
);
CREATE VIRTUAL TABLE extracted_text_fts USING fts5(
    markdown, content='extracted_text', content_rowid='rowid'
);
CREATE TRIGGER extracted_text_ai AFTER INSERT ON extracted_text BEGIN
    INSERT INTO extracted_text_fts(rowid, markdown) VALUES (new.rowid, new.markdown);
END;
CREATE TRIGGER extracted_text_ad AFTER DELETE ON extracted_text BEGIN
    INSERT INTO extracted_text_fts(extracted_text_fts, rowid, markdown) VALUES('delete', old.rowid, old.markdown);
END;
CREATE TRIGGER extracted_text_au AFTER UPDATE ON extracted_text BEGIN
    INSERT INTO extracted_text_fts(extracted_text_fts, rowid, markdown) VALUES('delete', old.rowid, old.markdown);
    INSERT INTO extracted_text_fts(rowid, markdown) VALUES (new.rowid, new.markdown);
END;

INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-1', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'abc', 1234, 42, 'Groundwork', 'Kant', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('/tmp/groundwork.pdf', 'doc-1', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');
INSERT INTO extracted_text(document_id, markdown, extracted_at, format)
VALUES ('doc-1',
        '## Page 1' || char(10) || char(10) || 'A preface.' || char(10) || char(10) ||
        '## Page 7' || char(10) || char(10) || 'the categorical imperative is a concept',
        '2026-01-01T00:00:00Z', 'markdown-v1');
INSERT INTO notes(document_id, body, created_at, updated_at)
VALUES ('doc-1', 'compare against Korsgaard', '2026-01-03T00:00:00Z', '2026-01-03T00:00:00Z');

-- A tag and a project with zero members each: list_tags and list_projects must still show
-- them, at count zero, rather than an INNER JOIN silently dropping the empty ones.
INSERT INTO tags(id, name) VALUES (1, 'ethics'), (2, 'unused');
INSERT INTO document_tags(document_id, tag_id) VALUES ('doc-1', 1);
INSERT INTO projects(id, name, created_at) VALUES (1, 'Dissertation', '2026-01-01T00:00:00Z'),
                                                   (2, 'Empty', '2026-01-02T00:00:00Z');
INSERT INTO project_members(project_id, document_id, added_at, section) VALUES (1, 'doc-1', '2026-01-01T00:00:00Z', 'background');

-- A second document sharing doc-1's content hash, so library-wide duplicate detection has
-- a pair to find.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-2', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', 'abc', 1234, 42, 'Groundwork (copy)', 'Kant', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('/tmp/groundwork-copy.pdf', 'doc-2', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');

-- A third document with no extracted_text row at all, and a location pointing at the real
-- PDF written above. doc-1 already has stored text, so read_document/read_page on it never
-- leave the cache-hit branch; doc-2 has neither stored text nor a file that exists on disk,
-- so nothing can extract from it either. doc-3 is the one document in this fixture for which
-- a read has to open the file, extract with PDFKit, and write the result back through
-- openLibraryForWriting/blocking/setExtractedText, which is otherwise never exercised.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-3', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, 580, 1, 'Hello', NULL, '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('$HELLO_PDF', 'doc-3', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');

-- Minor 6: a project holding one document with no extracted_text row at all, so
-- list_project_documents' without_text count has something real to assert on. Nothing else
-- in this script ever reads doc-4's text or calls read_document/search_documents on it, so
-- the check built on it does not depend on running before any particular point in the
-- script: it would report the same count no matter where it ran.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-4', '2026-01-04T00:00:00Z', '2026-01-04T00:00:00Z', NULL, 900, 3, 'Unread Paper', 'Someone', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('/tmp/unread.pdf', 'doc-4', '2026-01-04T00:00:00Z', '2026-01-04T00:00:00Z');
INSERT INTO projects(id, name, created_at) VALUES (3, 'Queue', '2026-01-04T00:00:00Z');
INSERT INTO project_members(project_id, document_id, added_at, section) VALUES (3, 'doc-4', '2026-01-04T00:00:00Z', NULL);

-- Important 1: doc-5 is a document row with no locations row at all -- the library has
-- indexed it, but has no location on record for it -- so a bibliography by document_ids
-- naming it must report the shortfall rather than silently citing one fewer than asked.
-- doc-6 is a real, second PDF (hello2.pdf) named alongside it in that same call, so the
-- check also proves the shortfall is reported next to an actual citation, not instead of one.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-5', '2026-01-05T00:00:00Z', '2026-01-05T00:00:00Z', NULL, 100, 2, 'Nowhere', 'Ghost', '{}');
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-6', '2026-01-06T00:00:00Z', '2026-01-06T00:00:00Z', NULL, 580, 1, 'Hello Two', NULL, '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('$HELLO2_PDF', 'doc-6', '2026-01-06T00:00:00Z', '2026-01-06T00:00:00Z');

-- Task 10 review findings: a trigger that makes filing doc-5 into any project fail, on
-- purpose, so add_to_project's partial-batch handling has a genuine per-document failure
-- to prove itself against. doc-5 already exists (Important 1, above) as a document row
-- with no location, is never given a locations row by any check, and nothing before this
-- point in the script ever adds it to a project, so poisoning it here changes no existing
-- check's outcome. A real BEFORE INSERT trigger raising ABORT is what a genuine write
-- failure (a full disk, a corrupt row, a constraint this schema does not model here)
-- looks like from add_to_project's own code, without needing to fabricate one.
CREATE TRIGGER poison_doc5_membership
BEFORE INSERT ON project_members
WHEN NEW.document_id = 'doc-5'
BEGIN
    SELECT RAISE(ABORT, 'simulated write failure for mcp-check');
END;

PRAGMA user_version = 7;
SQL

# Three separate runs of the server, each answering into the same combined stream: one era
# and folder-scanning pass with no environment override, one with the library-aware tools
# pointed at a path guaranteed not to exist, and one pointed at the scratch library above.
# Request ids are kept disjoint across the three so mcp-check.py, which keys purely by id, can
# check all of them from the one merged stream.
{
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_documents\",\"arguments\":{\"folder\":\"$FOLDER\"}}}" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_document","arguments":{"path":"/nope.pdf"}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}' \
  | "$BIN" 2>/dev/null

# The library-aware tools, with nothing indexed: pointed at a path guaranteed not to exist,
# independent of whatever real library.sqlite this machine's own copy of PaperShelf may or
# may not have built. Every one of them must answer politely (isError, not a crash or a
# JSON-RPC error) rather than trying to create a database of its own.
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"30","method":"tools/call","params":{"name":"list_projects","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"31","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"1"}}}' \
  '{"jsonrpc":"2.0","id":"32","method":"tools/call","params":{"name":"search_project","arguments":{"project":"1","query":"kant"}}}' \
  '{"jsonrpc":"2.0","id":"33","method":"tools/call","params":{"name":"list_tags","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"34","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"ethics"}}}' \
  | PAPERSHELF_LIBRARY_PATH="$FOLDER/no-such-library.sqlite" "$BIN" 2>/dev/null

# The same tools against the scratch library above, now six documents. The last four
# force pagination with an explicit small limit (ids 54-55, since the fixture is too small
# for any default limit to ever produce a next_cursor on its own), then confirm a cursor this
# server never handed out is refused rather than crashing or quietly resetting to offset
# zero: one that is not base64 at all (id 56), and one that is well-formed base64 but decodes
# to a negative offset, built the same way encodeCursor builds a real one, since that is the
# guard standing between a bad argument and an unclamped SQLite LIMIT reading negative as
# unlimited (id 57). Ids 58-61 exercise reading by document_id instead of path: a page read
# straight out of doc-1's stored text (58), its notes brought back alongside whatever PDFKit
# can find at its (nonexistent, in this fixture) path (59), a page range sliced out of the
# same stored text (60), and an id nothing in the library matches (61). Ids 62-64 exercise
# the write path end to end on doc-3, whose extracted_text row does not exist yet: a
# library-wide search for a word found only in its PDF comes back empty before anything has
# read it (62), read_document then reads the file and writes the result back (63), and the
# same search now finds it, which only happens if that write and the FTS triggers on it both
# actually ran (64). Ids 65-67 exercise Task 8's scoped bibliography and passaged project
# search: naming two scopes at once is refused rather than one of them winning quietly (65),
# search_project's hits now carry the same quoted passage and page number a library-wide
# search does (66), and a scope named with an empty string is refused with its own words
# rather than being read as though it had been left out and falling through to whichever
# other scope was actually named (67). Ids 68-70 close out this task's remaining review
# findings: list_project_documents' without_text count is exercised against a project
# ("Queue") that genuinely holds an unread member, rather than asserted nowhere (68); a
# bibliography by document_ids naming doc-6 (a real, citable file) alongside doc-5 (a
# document the library has indexed but has no location on record for) must report the
# shortfall rather than quietly citing one fewer than asked (69); and search_project, whose
# limit of 1 exactly exhausts Dissertation's one match, now emits next_cursor the same way
# list_documents and search_documents already do, rather than leaving a project with more
# matches than the default limit permanently truncated (70). Ids 71-77 are Task 10's first
# writing tools, both against doc-1: add_to_project files it into a project named for the
# first time, with a section and a note (71); list_projects confirms that project now
# exists with its one document (72); set_tags adds "kant" and removes "ethics" in the same
# call (73); documents_by_tag confirms the add landed (74) and the remove landed (75),
# rather than trusting the tool's own reported counts; and list_project_documents (76) and
# list_highlights (77) confirm the section and the note add_to_project also took landed,
# through tools that never call add_to_project themselves. Ids 78-86 close out the five
# review findings raised against these same two write tools: a project named purely with
# digits ("2024") is filed into once, not created twice, by two separate add_to_project
# calls (78, 79), confirmed by list_projects seeing exactly one "2024" with both documents
# as members and the same project id both calls reported (80); add_to_project naming doc-6
# (real) alongside doc-5 (poisoned by the trigger above, so filing it always fails) reports
# both outcomes rather than a bare failure (81), confirmed by list_project_documents seeing
# only the one that actually landed (82); set_tags re-adding "kant" to doc-1, which it
# already carries from id 73, reports that nothing changed rather than claiming fresh work
# (83), confirmed by documents_by_tag still finding exactly the one document it already did
# (84); and add_to_project naming "Reading list" in a different case ("READING LIST") with
# the same note as id 71 both reuses the existing project under its own stored name rather
# than echoing the caller's spelling, and does not add a second copy of a note doc-1 already
# carries (85), confirmed by list_highlights still finding exactly one "start here" note (86).
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"40","method":"tools/call","params":{"name":"list_projects","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"41","method":"tools/call","params":{"name":"list_tags","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"42","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Dissertation"}}}' \
  '{"jsonrpc":"2.0","id":"43","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"1"}}}' \
  '{"jsonrpc":"2.0","id":"44","method":"tools/call","params":{"name":"search_project","arguments":{"project":"1","query":"categorical imperative"}}}' \
  '{"jsonrpc":"2.0","id":"45","method":"tools/call","params":{"name":"search_project","arguments":{"project":"1","query":"nonexistentword"}}}' \
  '{"jsonrpc":"2.0","id":"46","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"ETHICS"}}}' \
  '{"jsonrpc":"2.0","id":"47","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"no-such-tag"}}}' \
  '{"jsonrpc":"2.0","id":"48","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"99"}}}' \
  '{"jsonrpc":"2.0","id":"49","method":"tools/call","params":{"name":"search_project","arguments":{"project":"2","query":"categorical"}}}' \
  '{"jsonrpc":"2.0","id":"50","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"1","limit":-1}}}' \
  '{"jsonrpc":"2.0","id":"51","method":"tools/call","params":{"name":"list_documents","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"52","method":"tools/call","params":{"name":"search_documents","arguments":{"query":"categorical imperative"}}}' \
  '{"jsonrpc":"2.0","id":"53","method":"tools/call","params":{"name":"find_duplicates","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"54","method":"tools/call","params":{"name":"list_documents","arguments":{"limit":1}}}' \
  '{"jsonrpc":"2.0","id":"55","method":"tools/call","params":{"name":"list_documents","arguments":{"limit":1,"cursor":"b2Zmc2V0OjE="}}}' \
  '{"jsonrpc":"2.0","id":"56","method":"tools/call","params":{"name":"list_documents","arguments":{"cursor":"not-a-real-cursor"}}}' \
  '{"jsonrpc":"2.0","id":"57","method":"tools/call","params":{"name":"list_documents","arguments":{"cursor":"b2Zmc2V0Oi0x"}}}' \
  '{"jsonrpc":"2.0","id":"58","method":"tools/call","params":{"name":"read_page","arguments":{"document_id":"doc-1","page":7}}}' \
  '{"jsonrpc":"2.0","id":"59","method":"tools/call","params":{"name":"list_highlights","arguments":{"document_id":"doc-1"}}}' \
  '{"jsonrpc":"2.0","id":"60","method":"tools/call","params":{"name":"read_document","arguments":{"document_id":"doc-1","pages":"7-7"}}}' \
  '{"jsonrpc":"2.0","id":"61","method":"tools/call","params":{"name":"read_document","arguments":{"document_id":"no-such-doc"}}}' \
  '{"jsonrpc":"2.0","id":"62","method":"tools/call","params":{"name":"search_documents","arguments":{"query":"hello"}}}' \
  '{"jsonrpc":"2.0","id":"63","method":"tools/call","params":{"name":"read_document","arguments":{"document_id":"doc-3"}}}' \
  '{"jsonrpc":"2.0","id":"64","method":"tools/call","params":{"name":"search_documents","arguments":{"query":"hello"}}}' \
  '{"jsonrpc":"2.0","id":"65","method":"tools/call","params":{"name":"bibliography","arguments":{"project":"Dissertation","folder":"/tmp"}}}' \
  '{"jsonrpc":"2.0","id":"66","method":"tools/call","params":{"name":"search_project","arguments":{"project":"1","query":"categorical imperative"}}}' \
  '{"jsonrpc":"2.0","id":"67","method":"tools/call","params":{"name":"bibliography","arguments":{"folder":""}}}' \
  '{"jsonrpc":"2.0","id":"68","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Queue"}}}' \
  '{"jsonrpc":"2.0","id":"69","method":"tools/call","params":{"name":"bibliography","arguments":{"document_ids":["doc-6","doc-5"]}}}' \
  '{"jsonrpc":"2.0","id":"70","method":"tools/call","params":{"name":"search_project","arguments":{"project":"1","query":"categorical imperative","limit":1}}}' \
  '{"jsonrpc":"2.0","id":"71","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"Reading list","document_ids":["doc-1"],"section":"to read","note":"start here"}}}' \
  '{"jsonrpc":"2.0","id":"72","method":"tools/call","params":{"name":"list_projects","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"73","method":"tools/call","params":{"name":"set_tags","arguments":{"document_ids":["doc-1"],"add":["kant"],"remove":["ethics"]}}}' \
  '{"jsonrpc":"2.0","id":"74","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"kant"}}}' \
  '{"jsonrpc":"2.0","id":"75","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"ethics"}}}' \
  '{"jsonrpc":"2.0","id":"76","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Reading list"}}}' \
  '{"jsonrpc":"2.0","id":"77","method":"tools/call","params":{"name":"list_highlights","arguments":{"document_id":"doc-1"}}}' \
  '{"jsonrpc":"2.0","id":"78","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"2024","document_ids":["doc-2"]}}}' \
  '{"jsonrpc":"2.0","id":"79","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"2024","document_ids":["doc-4"]}}}' \
  '{"jsonrpc":"2.0","id":"80","method":"tools/call","params":{"name":"list_projects","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":"81","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"Poison Test","document_ids":["doc-6","doc-5"]}}}' \
  '{"jsonrpc":"2.0","id":"82","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Poison Test"}}}' \
  '{"jsonrpc":"2.0","id":"83","method":"tools/call","params":{"name":"set_tags","arguments":{"document_ids":["doc-1"],"add":["kant"]}}}' \
  '{"jsonrpc":"2.0","id":"84","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"kant"}}}' \
  '{"jsonrpc":"2.0","id":"85","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"READING LIST","document_ids":["doc-1"],"note":"start here"}}}' \
  '{"jsonrpc":"2.0","id":"86","method":"tools/call","params":{"name":"list_highlights","arguments":{"document_id":"doc-1"}}}' \
  | PAPERSHELF_LIBRARY_PATH="$LIBRARY_DB" "$BIN" 2>/dev/null
} | python3 Tools/mcp-check.py
