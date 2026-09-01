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
sqlite3 "$LIBRARY_DB" <<'SQL'
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

# The same tools against the scratch library above. The last four force pagination with an
# explicit small limit against the fixture's two documents (ids 54-55, since the fixture is
# too small for any default limit to ever produce a next_cursor on its own), then confirm a
# cursor this server never handed out is refused rather than crashing or quietly resetting to
# offset zero: one that is not base64 at all (id 56), and one that is well-formed base64 but
# decodes to a negative offset, built the same way encodeCursor builds a real one, since that
# is the guard standing between a bad argument and an unclamped SQLite LIMIT reading negative
# as unlimited (id 57).
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
  | PAPERSHELF_LIBRARY_PATH="$LIBRARY_DB" "$BIN" 2>/dev/null
} | python3 Tools/mcp-check.py
