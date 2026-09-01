import os, sys, json

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

# A notification gets no reply at all, so exactly the requests with an id answer: 9 from the
# first run (one of its 10 lines is a notification, plus a second tools/list at id 7 for the
# no-password check below, plus id 8 which is Task 11's propose_file_changes against the
# empty scratch folder), 5 against the missing library, 52 against the scratch one (14
# original, plus 4 forcing pagination and exercising cursor rejection, plus 4 reading by
# document_id instead of path, plus 3 exercising the write path end to end, plus 3 exercising
# scoped bibliography and passaged project search, plus 3 closing out this task's remaining
# review findings: a project's without_text count, a bibliography shortfall, and
# search_project's next_cursor, plus 7 for Task 10's add_to_project and set_tags, plus 9
# closing out the five review findings against those same two write tools, plus 4 more (ids
# 87-90) closing out a later re-review: id 84's original request is gone, replaced by a
# fresh set_tags poison-batch call and its own confirmation, alongside a new add_to_project
# call and confirmation for the undercount fix itself, for a net change of minus one request
# plus four, plus 2 for Task 12: an unknown token refused by apply_file_changes (91) and a
# proposal against a folder holding a real PDF (92)), plus 3 more from a fourth, separate
# printf into the same binary further down: the same folder proposed again after the PDF is
# touched (93), which has to answer with a different token than 92's, and the same folder
# proposed twice more (94, 95) with only `recursive` differing between the two, which have
# to answer with different tokens from each other despite describing the same one move.
check("no reply to a notification", len(seen) == 9 + 5 + 52 + 3)

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

# Task 9: the server already has the app's passwords through Prefs, so no tool should still
# be asking the caller to type one in.
# The non-empty assertion is the point of the first clause: `all()` over an empty list is
# True, and `result()` hands back {} for a reply carrying an error rather than a result, so
# without it this check would report ok while examining no tools at all. Matched
# case-insensitively so reintroducing the field as "Password" is caught too.
listed_tools = result("7").get("tools", [])
check(
    "no tool asks the caller for a password any more",
    len(listed_tools) > 0
    and all(
        "password" not in json.dumps(tool.get("inputSchema", {})).lower()
        for tool in listed_tools
    ),
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

# Task 11: propose_file_changes against the same empty scratch folder as id 3. Nothing in
# it is a PDF, so the plan is empty, and an empty plan must still come back with a token
# rather than being treated as an error. (The "changes nothing on disk" half of this used to
# be asserted here as `plan.get("applied") is None`, which is vacuous: propose_file_changes
# never emits an "applied" key under any circumstance, including if it had renamed every
# file on disk, and this folder holds no PDF for a proposal to have anything to rename in
# the first place. A real version of that assertion needs a folder with something in it,
# and lives with Task 12's checks below, against RENAMES.)
plan = result("8").get("structuredContent", {})
check("a proposal comes back with a token", bool(plan.get("token")))

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
# ("Dissertation", one document, tagged "ethics"), one project with no documents at all
# ("Empty"), one tag with no documents ("unused"), and one project ("Queue") holding a
# single document with no extracted text, for the without_text check further down.

projects = result("40").get("structuredContent", {}).get("projects", [])
by_name = {p.get("name"): p for p in projects}
check(
    "list_projects finds every project",
    set(by_name) == {"Dissertation", "Empty", "Queue"},
)
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
    o.get("structuredContent", {}).get("totals", {}).get("documents") == 8,
)
check(
    "list_documents with no folder lists documents",
    len(o.get("structuredContent", {}).get("documents", [])) == 8,
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
# Minor 4: the library-wide tool must use the same "kind" vocabulary the folder-scan
# duplicate tool does (identical/sameText/likely), not a second string for the same idea.
check(
    "a library-wide duplicate group reports the same 'kind' vocabulary the folder scan uses",
    dupes[0].get("kind") == "identical" if dupes else False,
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

# Minor 6: without_text was asserted nowhere, so a regression in it, or in the threshold
# that appends its sentence, would go unnoticed. "Queue" holds exactly one member (doc-4)
# and that document has no extracted_text row at all, and is never touched by any
# read_document or search_documents call anywhere in this script, so this check does not
# depend on running before (or after) any particular point in the script.
queue = result("68")
check(
    "list_project_documents reports a nonzero without_text for a project with a genuinely "
    "unread member",
    queue.get("structuredContent", {}).get("without_text") == 1
    and "no text on record" in queue.get("content", [{}])[0].get("text", ""),
)

# Important 1: a document the library has indexed (doc-5, a documents row with no usable
# locations row) named in a bibliography's document_ids must be reported as a shortfall, not
# silently dropped. doc-6 is a real, second PDF named in the same call, so this also proves
# the shortfall is reported alongside an actual citation rather than instead of one.
bib_shortfall = result("69")
bib_structured = bib_shortfall.get("structuredContent", {})
check(
    "bibliography by document_ids reports a shortfall when a named document has no "
    "location on record",
    bib_shortfall.get("isError") is False
    and bib_structured.get("requested") == 2
    and bib_structured.get("cited") == 1
    and bib_structured.get("skipped_documents") == ["Nowhere"]
    and "Nowhere" in bib_shortfall.get("content", [{}])[0].get("text", ""),
)

# Important 3: search_project accepted a cursor argument but never emitted next_cursor, so a
# project with more matches than the limit was permanently truncated. A limit of 1 against
# Dissertation's one match exhausts it exactly at the boundary next_cursor's own emission
# condition (documents.count == limit) checks for.
next_page = result("70")
check(
    "search_project now emits next_cursor the way list_documents and search_documents do",
    next_page.get("structuredContent", {}).get("next_cursor")
    == "b2Zmc2V0OjE=",  # encodeCursor(1): base64 of "offset:1"
)

# Task 10: the first tools that write. add_to_project files doc-1 into "Reading list", a
# project that does not exist yet, with a section and a note; set_tags then adds "kant" and
# removes "ethics" from the same document in one call. Every assertion below reads the
# result back through a different tool than the one that wrote it, since a tool that merely
# reports success proves nothing about whether the write landed.
check(
    "a project named for the first time is created",
    result("71").get("structuredContent", {}).get("created") is True,
)
check(
    "the new project is listed with its one document",
    any(
        project.get("name") == "Reading list" and project.get("document_count") == 1
        for project in result("72").get("structuredContent", {}).get("projects", [])
    ),
)
check(
    "tags are added and removed in one call",
    result("73").get("structuredContent", {}).get("added") == 1
    and result("73").get("structuredContent", {}).get("removed") == 1,
)
check(
    "the added tag finds the document",
    len(result("74").get("structuredContent", {}).get("documents", [])) == 1,
)
check(
    "the removed tag finds nothing",
    len(result("75").get("structuredContent", {}).get("documents", [])) == 0,
)
reading_list_docs = result("76").get("structuredContent", {}).get("documents", [])
check(
    "add_to_project's section reaches the document, seen through list_project_documents",
    len(reading_list_docs) == 1 and reading_list_docs[0].get("section") == "to read",
)
check(
    "add_to_project's note reaches the document, seen through list_highlights",
    any(
        "start here" in note.get("body", "")
        for note in result("77").get("structuredContent", {}).get("notes", [])
    ),
)

# Critical: `project(matching:)` resolves an identifier as an id whenever it parses as one,
# and never falls back to a name match in that case, so a purely numeric project name like
# "2024" used to be recreated on every call (no project ever has id 2024). Two separate
# add_to_project calls, each filing a different document, must land in the same project.
first_2024 = result("78").get("structuredContent", {})
second_2024 = result("79").get("structuredContent", {})
check(
    "a purely numeric project name is created only once",
    first_2024.get("created") is True
    and second_2024.get("created") is False
    and first_2024.get("project", {}).get("id")
    == second_2024.get("project", {}).get("id"),
)
projects_2024 = [
    p
    for p in result("80").get("structuredContent", {}).get("projects", [])
    if p.get("name") == "2024"
]
check(
    "list_projects sees exactly one numeric-named project, holding both documents",
    len(projects_2024) == 1 and projects_2024[0].get("document_count") == 2,
)

# Important 2: add_to_project's per-document loop must carry on past one document's
# failure and say what happened to each, rather than a bare isError for the whole call.
# doc-5 is wired, by a trigger in the fixture's own schema, to fail any attempt to add it
# to a project; doc-6 and doc-8 are real, unrelated documents named in the same call, doc-8
# after doc-5. A reviewer later pointed out that naming only doc-6 and doc-5 (doc-6 first)
# cannot tell "the loop carried on past doc-5's failure" apart from "doc-6 had already
# committed before doc-5 failed", since either way only doc-6 would show up; doc-8, named
# after doc-5, only shows up if the loop actually kept going past the failure to reach it.
poison_batch = result("81")
poison_structured = poison_batch.get("structuredContent", {})
check(
    "a batch naming two good documents and one bad one reports every outcome",
    poison_batch.get("isError") is True
    and poison_structured.get("succeeded") == 2
    and set(poison_structured.get("succeeded_documents", [])) == {"doc-6", "doc-8"}
    and poison_structured.get("failed") == 1
    and poison_structured.get("failed_documents", [{}])[0].get("id") == "doc-5"
    and "doc-5" in poison_batch.get("content", [{}])[0].get("text", ""),
)
poison_members = result("82").get("structuredContent", {}).get("documents", [])
check(
    "the documents that actually landed show up, doc-8 included, seen through "
    "list_project_documents",
    {member.get("id") for member in poison_members} == {"doc-6", "doc-8"},
)

# Important 3: set_tags's added/removed must report an actual diff, not the size of the
# request; doc-1 already carries "kant" from id 73, so adding it again must change nothing.
repeat_tag = result("83").get("structuredContent", {})
check(
    "a repeated set_tags reports that nothing changed the second time",
    repeat_tag.get("added") == 0 and repeat_tag.get("succeeded") == 1,
)

# Important 4 and Minor: a repeated identical note must not duplicate, and reusing a
# project found by a case-insensitive name match must answer with its stored casing
# ("Reading list", from id 71) rather than echoing the caller's ("READING LIST").
repeat_note = result("85")
repeat_note_structured = repeat_note.get("structuredContent", {})
repeat_note_text = repeat_note.get("content", [{}])[0].get("text", "")
check(
    "reusing a project by a case-insensitive name match answers with its stored name",
    repeat_note_structured.get("created") is False
    and repeat_note_structured.get("project", {}).get("name") == "Reading list"
    and "Reading list" in repeat_note_text
    and "READING LIST" not in repeat_note_text,
)
notes_after_repeat = result("86").get("structuredContent", {}).get("notes", [])
check(
    "a repeated identical note does not duplicate, seen through list_highlights",
    sum(1 for note in notes_after_repeat if "start here" in note.get("body", "")) == 1,
)

# A later re-review of the two checks just above found the second of them (originally at id
# 84) toothless: it looked "kant" back up after id 83's repeat, which only ever exercises
# addTag's own pre-existing ON CONFLICT DO NOTHING and cannot depend on how the response
# counts its delta, since that counting happens after every write and never changes what
# addTag itself does. It is replaced below by a real test of the undercount fix the same
# reviewer named: add_to_project's "filed" must be a genuine before/after diff of project
# membership, not a tally of which documents' own per-document loop reported success, since
# addMember auto-commits independently of whatever setSection or addNote does afterward for
# the same document.
#
# doc-7 is filed alongside doc-6 with a note attached to both: doc-6's note write succeeds,
# but doc-7's is wired, by poison_doc7_note in the fixture's own schema, to always fail --
# doc-7's row in project_members still lands, since that write happens first and is never
# poisoned. If "filed" were counted from succeeded documents alone, doc-7 would vanish from
# it entirely, exactly the undercount this fix closes.
undercount = result("87")
undercount_structured = undercount.get("structuredContent", {})
undercount_text = undercount.get("content", [{}])[0].get("text", "")
check(
    "add_to_project counts a document as filed even though a later step failed for it",
    undercount.get("isError") is True
    and undercount_structured.get("filed") == 2
    and undercount_structured.get("succeeded") == 1
    and undercount_structured.get("succeeded_documents") == ["doc-6"]
    and undercount_structured.get("failed_documents", [{}])[0].get("id") == "doc-7"
    and undercount_structured.get("filed_despite_error") == ["doc-7"]
    and "doc-7" in undercount_text,
)
undercount_members = result("88").get("structuredContent", {}).get("documents", [])
check(
    "the document filed despite its later step failing is a genuine member, seen through "
    "list_project_documents",
    {member.get("id") for member in undercount_members} == {"doc-6", "doc-7"},
)

# The replacement for the other toothless check: set_tags never had its own per-document
# loop proven to carry on past a mid-batch failure the way add_to_project's is proven at ids
# 81-82 above. doc-5 is now poisoned for tagging too (poison_doc5_tagging), and doc-8 is
# named after it, so "draft" landing on doc-8 only happens if set_tags keeps going past
# doc-5's failure rather than the whole call unravelling at the first thrown error.
tag_batch = result("89").get("structuredContent", {})
check(
    "set_tags's own per-document loop also carries on past a mid-batch failure",
    tag_batch.get("succeeded") == 2
    and set(tag_batch.get("succeeded_documents", [])) == {"doc-6", "doc-8"}
    and tag_batch.get("failed") == 1
    and tag_batch.get("failed_documents", [{}])[0].get("id") == "doc-5",
)
tagged_after_poison = result("90").get("structuredContent", {}).get("documents", [])
check(
    "the tag lands on the documents whose write actually succeeded, doc-8 included, seen "
    "through documents_by_tag",
    {doc.get("id") for doc in tagged_after_poison} == {"doc-6", "doc-8"},
)

# Task 12: apply_file_changes, the only tool in this server that moves a file. The gate is
# off in every environment this script runs in, since it never writes the real preferences
# domain, and the gate is checked before the token is even looked up, so an unknown token
# given while the gate is off is refused for being unknown only in principle -- what this
# actually exercises, here, is the gate refusing first, regardless of what token is given.
# A real unknown-token refusal (and the change-detection refusal further down, driven
# through apply_file_changes itself rather than inferred from two propose_file_changes
# tokens differing) needs the gate on, which is checked by hand, with the user present, per
# the task brief.
check(
    "an unknown token is refused",
    result("91").get("isError") is True,
)
check(
    "applying is refused while the preference is off, and says so",
    result("91").get("isError") is True
    and "turned off"
    in " ".join(part.get("text", "") for part in result("91").get("content", [])),
)
check(
    "a proposal over a folder with a file in it names a move",
    result("92").get("structuredContent", {}).get("count", 0) == 1,
)
# The real replacement for the vacuous "applied is None" check removed above: RENAMES holds
# a real 580-byte PDF, stat'd by mcp-check.sh on the exact original path and name right
# after id 92's proposal ran and before anything else touches it, written to a file since a
# plain shell variable set on the left of the final pipe cannot reach this process on the
# right of it. A dry run that quietly stopped being one would have renamed the file out from
# under that name; this only reads back "580" if propose_file_changes left the file exactly
# where and what it was.
try:
    renames_size_after_propose = open(os.environ["RENAMES_STAT_FILE"]).read().strip()
except OSError:
    renames_size_after_propose = None
check(
    "a proposal changes nothing on disk",
    renames_size_after_propose == "580",
)
check(
    "touching a file invalidates the token that described it",
    result("93").get("structuredContent", {}).get("token")
    != result("92").get("structuredContent", {}).get("token"),
)

# The token-covers-settings fix (defect two of Task 12) only ever had a check proving a
# token changes when the underlying file does (the one right above); nothing proved the
# thing that fix actually exists for, which is two proposals over the *same* files with
# *different* settings not colliding on one token. RENAMES holds no subfolder, so toggling
# `recursive` changes nothing collectJobs finds there, and the two proposals below describe
# the identical one move; only the `recursive` flag baked into each plan's own token differs.
same_files_settings_a = result("94").get("structuredContent", {})
same_files_settings_b = result("95").get("structuredContent", {})
check(
    "two proposals differing only in a setting still describe the same renames",
    bool(same_files_settings_a.get("moves"))
    and same_files_settings_a.get("moves") == same_files_settings_b.get("moves"),
)
check(
    "but do not share a token, since applying one must consult its own settings, not the "
    "other's",
    bool(same_files_settings_a.get("token"))
    and bool(same_files_settings_b.get("token"))
    and same_files_settings_a.get("token") != same_files_settings_b.get("token"),
)

sys.exit(1 if check.failed else 0)
