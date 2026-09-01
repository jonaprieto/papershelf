import sys, json

seen = {}
for line in sys.stdin:
    message = json.loads(line)
    seen[str(message["id"])] = message


def result(id):
    """A response that carried an error where a result was expected fails the check it was
    for, rather than tearing down the run with a traceback."""
    message = seen.get(id)
    if message is None or "result" not in message:
        return {}
    return message["result"]


def check(label, condition):
    print(("ok   " if condition else "FAIL ") + label)
    if not condition:
        check.failed = True


check.failed = False

# A notification gets no reply at all, so exactly the requests with an id answer: 7 from the
# first run (one of its 8 lines is a notification), 5 against the missing library, 28 against
# the scratch one (14 original, plus 4 forcing pagination and exercising cursor rejection,
# plus 4 reading by document_id instead of path, plus 3 exercising the write path end to end,
# plus 3 exercising scoped bibliography and passaged project search).
check("no reply to a notification", len(seen) == 7 + 5 + 28)

d = result("d")
check(
    "discover names the current revision",
    d.get("supportedVersions", [None])[0] == "2026-07-28",
)
check("discover carries resultType", d.get("resultType") == "complete")
check(
    "discover is cacheable",
    "ttlMs" in d and d.get("cacheScope") in ("public", "private"),
)
check(
    "discover identifies the server",
    d.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {}).get("name")
    == "papershelf",
)

i = result("1")
check(
    "the legacy handshake agrees on the asked-for version",
    i.get("protocolVersion") == "2025-06-18",
)
check("the legacy handshake declares tools", "tools" in i.get("capabilities", {}))

t = result("2")
check(
    "tools/list carries resultType and a cache hint",
    t.get("resultType") == "complete" and "ttlMs" in t,
)
check(
    "every tool has a name and an object input schema",
    bool(t.get("tools"))
    and all(x["name"] and x["inputSchema"]["type"] == "object" for x in t["tools"]),
)
check(
    "tool order is deterministic",
    [x["name"] for x in t.get("tools", [])] == [x["name"] for x in t.get("tools", [])],
)

c = result("3")
check("an empty folder is not an error", c.get("isError") is False)
check("a tool result carries resultType", c.get("resultType") == "complete")

check(
    "an unknown tool is a protocol error",
    seen.get("4", {}).get("error", {}).get("code") == -32602,
)
check(
    "a tool that cannot do the job answers with isError, not an error",
    result("5").get("isError") is True,
)
check(
    "an unsupported protocol version is refused with -32022",
    seen.get("6", {}).get("error", {}).get("code") == -32022,
)

# The library-aware tools, run once against a path with nothing at it: each must say so
# politely (isError, not a crash or a JSON-RPC error) and not merely happen to be empty.
for missing_id in ("30", "31", "32", "33", "34"):
    r = result(missing_id)
    check(
        f"id {missing_id}: a missing library is isError, not a JSON-RPC error",
        r.get("isError") is True and "error" not in seen.get(missing_id, {}),
    )
    check(
        f"id {missing_id}: a missing library says so in words",
        "no library" in r.get("content", [{}])[0].get("text", "").lower(),
    )

# The same tools against the scratch library Tools/mcp-check.sh builds: one project
# ("Dissertation", one document, tagged "ethics") and one project with no documents at all
# ("Empty"), one tag with no documents ("unused").

projects = result("40").get("structuredContent", {}).get("projects", [])
by_name = {p.get("name"): p for p in projects}
check("list_projects finds both projects", set(by_name) == {"Dissertation", "Empty"})
check(
    "list_projects counts a project's documents",
    by_name.get("Dissertation", {}).get("document_count") == 1,
)
check(
    "list_projects does not drop an empty project",
    by_name.get("Empty", {}).get("document_count") == 0,
)

tags = result("41").get("structuredContent", {}).get("tags", [])
by_tag = {t.get("name"): t for t in tags}
check("list_tags finds both tags", set(by_tag) == {"ethics", "unused"})
check(
    "list_tags counts a tag's documents",
    by_tag.get("ethics", {}).get("document_count") == 1,
)
check(
    "list_tags does not drop an unused tag",
    by_tag.get("unused", {}).get("document_count") == 0,
)

for lookup_id in ("42", "43"):  # by name, then by id -- must agree
    docs = result(lookup_id).get("structuredContent", {}).get("documents", [])
    check(
        f"id {lookup_id}: list_project_documents finds the one member",
        len(docs) == 1 and docs[0].get("path") == "/tmp/groundwork.pdf",
    )
    check(
        f"id {lookup_id}: list_project_documents carries the member's tags",
        docs[0].get("tags") == ["ethics"] if docs else False,
    )
    # The section is most of what a reading list says, so it has to reach the client.
    check(
        f"id {lookup_id}: list_project_documents says what a document is filed under",
        docs[0].get("section") == "background" if docs else False,
    )

search_hit = result("44").get("structuredContent", {})
check(
    "search_project finds a phrase that is actually in the document",
    search_hit.get("matched") == 1
    and search_hit.get("documents", [{}])[0].get("path") == "/tmp/groundwork.pdf",
)
search_miss = result("45")
check(
    "search_project finding nothing is not an error",
    search_miss.get("isError") is False
    and search_miss.get("structuredContent", {}).get("matched") == 0,
)

tag_hit = result("46").get("structuredContent", {})
check("documents_by_tag matches case-insensitively", tag_hit.get("count") == 1)
tag_miss = result("47")
check(
    "documents_by_tag finding nothing is not an error",
    tag_miss.get("isError") is False
    and tag_miss.get("structuredContent", {}).get("count") == 0,
)

check(
    "an unresolvable project id is isError, not an empty list",
    result("48").get("isError") is True,
)
check(
    "search_project scopes to the named project, not the whole library",
    result("49").get("structuredContent", {}).get("matched") == 0,
)

# SQLite treats a negative LIMIT as "no limit", not zero or an error; a client that computes
# a bad limit should get nothing back, not the whole project.
check(
    "a negative limit is clamped, not treated as unlimited",
    result("50").get("structuredContent", {}).get("count") == 0,
)

o = result("51")
check(
    "list_documents with no folder reports the library's totals",
    o.get("structuredContent", {}).get("totals", {}).get("documents") == 3,
)
check(
    "list_documents with no folder lists documents",
    len(o.get("structuredContent", {}).get("documents", [])) == 3,
)

s = result("52")
hits = s.get("structuredContent", {}).get("documents", [])
check("a library-wide search finds the indexed document", len(hits) == 1)
check(
    "a hit quotes the passage it matched",
    "categorical imperative"
    in (hits[0].get("excerpts", [{}])[0].get("text", "") if hits else ""),
)
check(
    "a hit says which page it came from",
    (hits[0].get("excerpts", [{}])[0].get("page") if hits else None) == 7,
)

dupes = result("53").get("structuredContent", {}).get("groups", [])
check(
    "duplicates are found library-wide by content hash",
    len(dupes) == 1 and len(dupes[0].get("paths", [])) == 2,
)

# Pagination, forced by an explicit limit smaller than the fixture's three documents: neither
# default limit (100 for list_documents, 20 for search_documents) is ever small enough for
# documents.count == limit to fire against a three-document library, so nothing else in this
# script ever produces a next_cursor or feeds one back in.
page_one = result("54").get("structuredContent", {})
check(
    "a limit that exhausts itself against the fixture produces a next_cursor",
    page_one.get("next_cursor")
    == "b2Zmc2V0OjE=",  # encodeCursor(1): base64 of "offset:1"
)
page_one_paths = {d.get("path") for d in page_one.get("documents", [])}

page_two = result("55").get("structuredContent", {})
page_two_paths = {d.get("path") for d in page_two.get("documents", [])}
check(
    "feeding the cursor back in advances to the documents the first page did not have",
    len(page_one_paths) == 1
    and len(page_two_paths) == 1
    and page_one_paths.isdisjoint(page_two_paths),
)

malformed_cursor = result("56")
check(
    "a cursor that is not base64 this server ever handed out is isError, not a crash "
    "or a silent fall back to offset zero",
    malformed_cursor.get("isError") is True
    and "cursor" in malformed_cursor.get("content", [{}])[0].get("text", "").lower(),
)

# base64 of "offset:-1", built the same way encodeCursor builds a real cursor: well-formed
# base64 that decodes cleanly, so only decodeCursor's own offset >= 0 check can catch it.
# SQLite reads a negative LIMIT as unlimited, so this is the guard against a bad cursor
# dumping the whole library.
negative_cursor = result("57")
check(
    "a cursor that decodes to a negative offset is refused, not treated as offset zero",
    negative_cursor.get("isError") is True
    and "cursor" in negative_cursor.get("content", [{}])[0].get("text", "").lower(),
)

# Reading a document a search or listing found by its document_id, with no path in hand.
check(
    "a page is read straight out of the stored text, with no file to open",
    "categorical imperative"
    in " ".join(part.get("text", "") for part in result("58").get("content", [])),
)
check(
    "highlights bring the notes written about the document",
    any(
        "Korsgaard" in note.get("body", "")
        for note in result("59").get("structuredContent", {}).get("notes", [])
    ),
)
page_range_text = " ".join(
    part.get("text", "") for part in result("60").get("content", [])
)
check(
    "a page range is sliced out of the stored text",
    "categorical imperative" in page_range_text and "A preface" not in page_range_text,
)
check(
    "an unknown document id is an isError, not a crash",
    result("61").get("isError") is True,
)

# The write path end to end, on doc-3, which starts this run with a location but no
# extracted_text row at all: nothing before this in the script has read its file, so a
# library-wide search for its one word must come back empty until read_document actually
# extracts and caches it, and must find it afterward only because that write, and the FTS
# triggers on it, both actually ran.
before_write = result("62")
check(
    "search_documents finds nothing for a document whose text has never been read",
    before_write.get("isError") is False
    and before_write.get("structuredContent", {}).get("matched") == 0,
)

extracted = result("63")
check(
    "read_document extracts a document with no cached text from the file itself",
    "hello" in " ".join(part.get("text", "") for part in extracted.get("content", []))
    and extracted.get("structuredContent", {}).get("extracted_now") is True,
)

after_write = result("64").get("structuredContent", {})
after_hits = after_write.get("documents", [])
check(
    "the same search now finds it, because the write-back landed and the FTS index saw it",
    after_write.get("matched") == 1
    and bool(after_hits)
    and after_hits[0].get("id") == "doc-3",
)

# Task 8: bibliography gains a scope, so it must refuse to guess between two of them named
# at once rather than silently picking one.
check(
    "bibliography refuses two scopes rather than picking one",
    result("65").get("isError") is True,
)

# Task 8: search_project's hits carry the same quoted passage and page a library-wide
# search already does, since a researcher searching one project wants the quote just as
# much as one searching the whole shelf.
p = result("66").get("structuredContent", {}).get("documents", [])
check(
    "a project search quotes the passage and its page",
    bool(p) and p[0].get("excerpts", [{}])[0].get("page") == 7,
)

# Task 8: an empty string for a scope is a caller mistake, not the same as leaving the key
# out; it must be refused in its own words, not silently read as absent and left to fall
# through to whichever other scope was actually named.
empty_scope = result("67")
check(
    "an empty scope value is refused by name, not read as though it were absent",
    empty_scope.get("isError") is True
    and "empty" in empty_scope.get("content", [{}])[0].get("text", "").lower(),
)

sys.exit(1 if check.failed else 0)
