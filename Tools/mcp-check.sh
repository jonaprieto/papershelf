#!/usr/bin/env bash
# Drive the MCP server over stdio and check every answer, both protocol eras.
# Usage: Tools/mcp-check.sh [path-to-binary]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-$(swift build --show-bin-path)/PaperShelfMCP}"
[[ -x "$BIN" ]] || { echo "no binary at $BIN; run 'swift build' first" >&2; exit 1; }

FOLDER="$(mktemp -d)"
trap 'rm -rf "$FOLDER"' EXIT

# A real, minimal PDF, so a rename plan has something in it. Its own folder, because the
# first block asserts that scanning $FOLDER finds nothing.
RENAMES="$FOLDER/renames"
mkdir -p "$RENAMES"

# A scratch plans directory, pointed to by PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY on
# every invocation of $BIN below, so that every propose_file_changes call in this script,
# including id 8's, writes into a folder this script owns and this script's own trap
# cleans up, rather than into the real ~/Library/Application Support/PaperShelf/ a copy of
# PaperShelf on this machine might be using: that is exactly how litter from a manual
# verification pass reached a real user's disk in the first place.
PLANS_DIR="$FOLDER/plans"
mkdir -p "$PLANS_DIR"

# Where the "did a proposal actually leave the file alone" stat below is recorded. The
# request/response block that fills this in runs on the left of the final pipe to
# mcp-check.py, which bash runs as its own subshell, so a plain variable set there would not
# survive to reach the python3 process on the right of that same pipe; a file both sides can
# see does.
RENAMES_STAT_FILE="$FOLDER/renames-size-after-propose.txt"
base64 -d > "$RENAMES/Some Paper (2024).pdf" <<'PDF'
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

# A third copy, at yet another distinct path, for the same reason: the bibliography
# cap-visibility check below needs one real, citable file among its 1001 synthetic
# documents, so `bibliographyPaths` has something to build a path list out of rather than
# throwing "nothing to cite there" before the cap it is meant to exercise is ever reached.
HELLO3_PDF="$FOLDER/hello3.pdf"
cp "$HELLO_PDF" "$HELLO3_PDF"

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
--
-- This trigger fires on the INSERT into project_members, which is the first of
-- add_to_project's three writes: it can only ever fail a document at addMember itself, and
-- so it cannot exercise "addMember committed, a later write then failed", which is the
-- shape of the undercounting fix below. doc-7 and the second trigger, further down, cover
-- that case instead.
CREATE TRIGGER poison_doc5_membership
BEFORE INSERT ON project_members
WHEN NEW.document_id = 'doc-5'
BEGIN
    SELECT RAISE(ABORT, 'simulated write failure for mcp-check');
END;

-- Task 10 second review findings, part one: doc-7 is filed successfully -- its INSERT into
-- project_members is never poisoned -- but a note attached to it in the same call always
-- fails, because the trigger below fires on the INSERT into notes instead. That is a
-- genuine "membership landed, a later step failed" for add_to_project to report honestly:
-- filed for doc-7 must count it even though it is also in failed_documents.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-7', '2026-01-07T00:00:00Z', '2026-01-07T00:00:00Z', NULL, 100, 1, 'Filed Then Failed', 'Nobody', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('/tmp/filed-then-failed.pdf', 'doc-7', '2026-01-07T00:00:00Z', '2026-01-07T00:00:00Z');

CREATE TRIGGER poison_doc7_note
BEFORE INSERT ON notes
WHEN NEW.document_id = 'doc-7'
BEGIN
    SELECT RAISE(ABORT, 'simulated write failure for mcp-check');
END;

-- Task 10 second review findings, part two: doc-8 is a plain document, poisoned nowhere,
-- used only as the third member of a batch that also names doc-5. Naming it after doc-5
-- proves that add_to_project's and set_tags's per-document loops carry on to a document
-- that comes after a failure, not merely that an earlier document had already committed
-- before the failure happened. A second trigger poisons doc-5's own tag writes the same
-- way poison_doc5_membership poisons its project writes, so set_tags has the same kind of
-- genuine mid-batch failure to prove itself against as add_to_project already does.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-8', '2026-01-08T00:00:00Z', '2026-01-08T00:00:00Z', NULL, 100, 1, 'Comes After The Poison', 'Nobody', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('/tmp/comes-after-poison.pdf', 'doc-8', '2026-01-08T00:00:00Z', '2026-01-08T00:00:00Z');

CREATE TRIGGER poison_doc5_tagging
BEFORE INSERT ON document_tags
WHEN NEW.document_id = 'doc-5'
BEGIN
    SELECT RAISE(ABORT, 'simulated write failure for mcp-check');
END;

-- Critical fix mutation coverage: doc-9 is a document row whose one recorded location does
-- not exist on disk, and which the fixture never gives extracted text or a note either --
-- exactly what apply_file_changes moving a file without recording the move (the bug this
-- fix closes) leaves behind. list_highlights/read_document/read_page against it, with
-- nothing to fall back on, must say the file cannot be found rather than reporting nothing
-- marked or a misleading "may be locked, or a scan" -- the false-empty and misleading-error
-- this fix's resolveDocument/storedOrExtracted changes exist to close. Without those
-- changes, this would instead answer with an ordinary, successful-looking empty result.
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
VALUES ('doc-9', '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z', NULL, 100, 1, 'Missing File', 'Nobody', '{}');
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
VALUES ('$FOLDER/vanished.pdf', 'doc-9', '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z');

-- Minor fix coverage: a project and a tag whose true membership (1001) exceeds
-- bibliographyPaths' own 1000-document cap, so a bibliography naming either can prove the
-- cap's own shortfall -- "not_considered" -- is now reported rather than silently
-- swallowed. Built with a recursive CTE rather than 1001 literal INSERT statements per
-- table. Every one of the 1001 gets a locations row -- cap-doc-0001 a real, openable file
-- (hello3.pdf), the other 1000 a path that does not exist -- so every document considered
-- within the cap already has "a location on record" and the ordinary shortfall (Important
-- 1, above) never fires here, keeping this check isolated to the cap it is actually about.
-- cap-doc-0001 is pinned first in both orderings bibliographyPaths' two capped queries
-- use -- documents(inProject:limit:)'s ascending added_at, documents(taggedWith:limit:)'s
-- descending last_seen_at -- so it always lands inside the capped 1000 rather than
-- depending on how SQLite breaks a tie among 1001 identical timestamps.
INSERT INTO tags(id, name) VALUES (3, 'bulk');
INSERT INTO projects(id, name, created_at) VALUES (4, 'Big Project', '2026-01-09T00:00:00Z');
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 1001
)
INSERT INTO documents(id, first_seen_at, last_seen_at, content_hash, byte_count, page_count, title, author, document_info)
SELECT 'cap-doc-' || printf('%04d', n), '2026-01-09T00:00:00Z',
       CASE WHEN n = 1 THEN '2026-01-10T00:00:00Z' ELSE '2026-01-09T00:00:00Z' END,
       NULL, 10, 1, 'Cap Doc ' || n, NULL, '{}'
FROM seq;
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 1001
)
INSERT INTO project_members(project_id, document_id, added_at, section)
SELECT 4, 'cap-doc-' || printf('%04d', n),
       CASE WHEN n = 1 THEN '2026-01-08T00:00:00Z' ELSE '2026-01-09T00:00:00Z' END,
       NULL
FROM seq;
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 1001
)
INSERT INTO document_tags(document_id, tag_id)
SELECT 'cap-doc-' || printf('%04d', n), 3
FROM seq;
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 1001
)
INSERT INTO locations(path, document_id, first_seen_at, last_seen_at)
SELECT CASE WHEN n = 1 THEN '$HELLO3_PDF' ELSE '/tmp/cap-doc-' || printf('%04d', n) || '.pdf' END,
       'cap-doc-' || printf('%04d', n), '2026-01-09T00:00:00Z', '2026-01-09T00:00:00Z'
FROM seq;

-- Important fix coverage: a bare LibraryError thrown from outside any tool's own
-- per-document try/catch used to reach Server.swift's top-level catch and be rendered
-- through error.localizedDescription, which LibraryError cannot back sensibly (it
-- conforms to neither LocalizedError nor CustomNSError) -- Foundation's generic "The
-- operation couldn't be completed." instead of the real message. createProject, called
-- by add_to_project outside its per-document loop, is such a call: this trigger makes it
-- throw a genuine LibraryError.sqlite, unwrapped, for exactly one project name.
CREATE TRIGGER poison_project_creation
BEFORE INSERT ON projects
WHEN NEW.name = 'Poison Project Creation'
BEGIN
    SELECT RAISE(ABORT, 'simulated write failure for mcp-check');
END;

PRAGMA user_version = 7;
SQL

# Coverage for the sweep that removes expired plans: two files planted straight into
# $PLANS_DIR, shaped only as far as sweepExpiredPlans actually looks (a
# pending-plan-<hex>.json name, and a createdAt field it can parse on its own), since the
# check script cannot control the clock and so cannot wait fifteen minutes for a real plan
# to expire on its own. STALE_PLAN's createdAt is decades in the past, so it is already
# older than RenamePlan.lifetime by the time anything reads it; FRESH_PLAN's is the current
# moment, so it is nowhere near expired. Neither file is a complete RenamePlan (no folder,
# no moves, no token matching its own hash) on purpose: sweepExpiredPlans is documented to
# judge age from createdAt alone, independent of whether the rest of a plan can still be
# decoded, and a minimal file like these is what actually proves that rather than merely
# exercising the common case of a plan this same binary also wrote.
STALE_PLAN="$PLANS_DIR/pending-plan-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
FRESH_PLAN="$PLANS_DIR/pending-plan-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"
printf '{"createdAt":"2000-01-01T00:00:00Z"}' > "$STALE_PLAN"
printf '{"createdAt":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FRESH_PLAN"

# Three separate runs of the server, each answering into the same combined stream: one era
# and folder-scanning pass, one with the library-aware tools pointed at a path guaranteed
# not to exist, and one pointed at the scratch library above. Every one of the three is
# pointed at $PLANS_DIR rather than the real Application Support folder. Request ids are
# kept disjoint across the three so mcp-check.py, which keys purely by id, can check all of
# them from the one merged stream.
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
  "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$FOLDER\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":\"96\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\"}}}" \
  | PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY="$PLANS_DIR" "$BIN" 2>/dev/null

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
  | PAPERSHELF_LIBRARY_PATH="$FOLDER/no-such-library.sqlite" \
    PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY="$PLANS_DIR" "$BIN" 2>/dev/null

# The same tools against the scratch library above, now eight documents. The last four
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
# as members and the same project id both calls reported (80); add_to_project naming doc-6,
# doc-5 (poisoned by the trigger above, so filing it always fails), then doc-8, in that
# order, reports every outcome rather than a bare failure (81), confirmed by
# list_project_documents seeing the two that actually landed and, since doc-8 comes after
# doc-5 in the request, that a failure in the middle of the batch does not stop the document
# named after it (82); set_tags re-adding "kant" to doc-1, which it already carries from id
# 73, reports that nothing changed rather than claiming fresh work (83); and add_to_project
# naming "Reading list" in a different case ("READING LIST") with the same note as id 71
# both reuses the existing project under its own stored name rather than echoing the
# caller's spelling, and does not add a second copy of a note doc-1 already carries (85),
# confirmed by list_highlights still finding exactly one "start here" note (86). Ids 87-90
# close out a later re-review of ids 82 and 84 themselves. (82) originally named only doc-6
# and doc-5, so the one document it found had already committed before doc-5 failed and
# would have shown up whether or not the per-document try/catch it was meant to prove ever
# ran; doc-8 above, named third, is what turns it into a real test of carrying on past a
# failure rather than a document that would have landed regardless. (84) originally looked
# "kant" back up after the id-83 repeat, which only ever exercises addTag's own pre-existing
# ON CONFLICT DO NOTHING and says nothing about how the response counts its delta; ids
# 87-90 replace it with a check set_tags never had: doc-7 proves add_to_project's own
# undercount directly, since its addMember always lands but the note in the same call always
# fails for it (poison_doc7_note above), so filed must count it even though it is also in
# failed_documents (87), confirmed by list_project_documents seeing it as a genuine member
# (88); and a set_tags call naming doc-6, doc-5 (now poisoned for tagging too, by
# poison_doc5_tagging above), then doc-8, proves set_tags's own per-document loop carries on
# past a mid-batch failure the same way add_to_project's does (89), confirmed by
# documents_by_tag finding the tag on doc-6 and doc-8 but not doc-5 (90). Task 12's
# apply_file_changes closes this run out: an unknown token is refused (91), a real PDF in
# its own folder (RENAMES, not the empty FOLDER id 8 already covers) gives propose_file_changes
# something to plan a move for (92), and the same folder proposed again after a byte is
# appended to that PDF (93, in the block below) must come back with a different token, since
# a token that survived that would not be able to tell a stale plan from a current one. Ids
# 94 and 95, in that same block, close out the review finding that the token-covers-settings
# fix (defect two, above) had no test proving the thing it actually fixes: two proposals
# against that same touched file, differing only in `recursive`, must still describe the
# same one move (RENAMES holds no subfolder, so `recursive` changes nothing about what is
# found) but must not share a token, since applying one has to consult its own plan's
# settings, not the other's. Id 96, back in the first block above, is the sweep coverage
# for the litter fix: a plain propose_file_changes call against RENAMES, which writePlan
# already runs on every call regardless of what it is proposing, so by the time it answers,
# STALE_PLAN (planted with a decades-old createdAt, before the first block ran) must be
# gone, and FRESH_PLAN (planted alongside it, with a current createdAt) must still be
# there. mcp-check.py checks both files directly rather than through any reply, since a
# swept file leaves no reply of its own to check.
#
# Ids 97-102 close out the final whole-branch review. 97-99 are the Critical fix's mutation
# coverage: doc-9's one recorded location does not exist on disk, and the fixture gives it
# neither cached text nor a note, so there is nothing for list_highlights (97),
# read_document (98) or read_page (99) to fall back on -- exactly the state a rename
# apply_file_changes moved without recording (the bug this fix closes) leaves a document
# in. Before the fix each of the three answered with an ordinary, successful-looking empty
# or misleadingly-specific result; after it, each has to say plainly that the file cannot
# be found. 100 and 101 are the bibliography cap-visibility fix: "Big Project" and "bulk"
# each hold 1001 documents against bibliographyPaths' own 1000-document cap, so a
# bibliography naming either must report that 1 document was never even considered, not
# silently answer as though 1000 were the whole scope. 102 is the LibraryError-message
# fix: add_to_project, naming a project that does not exist yet ("Poison Project
# Creation"), calls `createProject` outside its per-document try/catch, and the trigger
# planted on `projects` above makes that call throw a real `LibraryError.sqlite` -- this is
# what proves Server.swift's top-level catch now renders it as that error's own message
# rather than Foundation's generic "The operation couldn't be completed." 103 and 104 are
# the limit-clamping consistency fix: list_project_documents and documents_by_tag, asked
# for 5000 documents from "Big Project"/"bulk" (1001 real members apiece), must still
# clamp to the same 1000-document policy `bibliographyPaths` already enforces, the same
# way list_documents and search_documents already clamped their own upper bound before
# this fix.
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
  '{"jsonrpc":"2.0","id":"81","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"Poison Test","document_ids":["doc-6","doc-5","doc-8"]}}}' \
  '{"jsonrpc":"2.0","id":"82","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Poison Test"}}}' \
  '{"jsonrpc":"2.0","id":"83","method":"tools/call","params":{"name":"set_tags","arguments":{"document_ids":["doc-1"],"add":["kant"]}}}' \
  '{"jsonrpc":"2.0","id":"85","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"READING LIST","document_ids":["doc-1"],"note":"start here"}}}' \
  '{"jsonrpc":"2.0","id":"86","method":"tools/call","params":{"name":"list_highlights","arguments":{"document_id":"doc-1"}}}' \
  '{"jsonrpc":"2.0","id":"87","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"Undercount Test","document_ids":["doc-6","doc-7"],"note":"keep reading"}}}' \
  '{"jsonrpc":"2.0","id":"88","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Undercount Test"}}}' \
  '{"jsonrpc":"2.0","id":"89","method":"tools/call","params":{"name":"set_tags","arguments":{"document_ids":["doc-6","doc-5","doc-8"],"add":["draft"]}}}' \
  '{"jsonrpc":"2.0","id":"90","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"draft"}}}' \
  '{"jsonrpc":"2.0","id":"97","method":"tools/call","params":{"name":"list_highlights","arguments":{"document_id":"doc-9"}}}' \
  '{"jsonrpc":"2.0","id":"98","method":"tools/call","params":{"name":"read_document","arguments":{"document_id":"doc-9"}}}' \
  '{"jsonrpc":"2.0","id":"99","method":"tools/call","params":{"name":"read_page","arguments":{"document_id":"doc-9","page":1}}}' \
  '{"jsonrpc":"2.0","id":"100","method":"tools/call","params":{"name":"bibliography","arguments":{"project":"Big Project"}}}' \
  '{"jsonrpc":"2.0","id":"101","method":"tools/call","params":{"name":"bibliography","arguments":{"tag":"bulk"}}}' \
  '{"jsonrpc":"2.0","id":"102","method":"tools/call","params":{"name":"add_to_project","arguments":{"project":"Poison Project Creation","document_ids":["doc-1"]}}}' \
  '{"jsonrpc":"2.0","id":"103","method":"tools/call","params":{"name":"list_project_documents","arguments":{"project":"Big Project","limit":5000}}}' \
  '{"jsonrpc":"2.0","id":"104","method":"tools/call","params":{"name":"documents_by_tag","arguments":{"tag":"bulk","limit":5000}}}' \
  '{"jsonrpc":"2.0","id":"91","method":"tools/call","params":{"name":"apply_file_changes","arguments":{"token":"deadbeef"}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":\"92\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\"}}}" \
  | PAPERSHELF_LIBRARY_PATH="$LIBRARY_DB" \
    PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY="$PLANS_DIR" "$BIN" 2>/dev/null

# What id 92's proposal actually left on disk, captured before the comment below is
# appended: the real test that a proposal (a dry run) changes nothing, since the old
# assertion (`plan.get("applied") is None`) was vacuous -- propose_file_changes never emits
# an "applied" key under any circumstance, including if it had renamed every file on disk.
# A dry run that quietly stopped being one would rename this file out from under its own
# name, so `stat` on the exact original path and name comes back empty; one that stayed a
# dry run leaves the original 580 bytes exactly where they were.
stat -f%z "$RENAMES/Some Paper (2024).pdf" > "$RENAMES_STAT_FILE" 2>/dev/null || echo -1 > "$RENAMES_STAT_FILE"

# The same folder proposed twice with a byte written to the fixture in between. A token that
# survives that would be a token that cannot tell a stale plan from a current one, which is
# the whole thing standing between apply_file_changes and a file it was never shown. A PDF
# comment appended after %%EOF is still a PDF PDFKit opens, so the second proposal still
# finds the same one move; only the file's size and modification date differ, which is
# exactly what the token has to notice.
printf '%%comment\n' >> "$RENAMES/Some Paper (2024).pdf"
printf '%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":\"93\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":\"94\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\",\"recursive\":true}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":\"95\",\"method\":\"tools/call\",\"params\":{\"name\":\"propose_file_changes\",\"arguments\":{\"folder\":\"$RENAMES\",\"recursive\":false}}}" \
  | PAPERSHELF_LIBRARY_PATH="$LIBRARY_DB" \
    PAPERSHELF_TEST_PLANS_PATH_FOR_TESTS_ONLY="$PLANS_DIR" "$BIN" 2>/dev/null
} | RENAMES_STAT_FILE="$RENAMES_STAT_FILE" \
    SWEEP_STALE_PLAN="$STALE_PLAN" SWEEP_FRESH_PLAN="$FRESH_PLAN" \
    python3 Tools/mcp-check.py
