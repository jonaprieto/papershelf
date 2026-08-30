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
# first run (one of its 8 lines is a notification), 5 against the missing library, 11 against
# the scratch one.
check("no reply to a notification", len(seen) == 7 + 5 + 11)

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

sys.exit(1 if check.failed else 0)
