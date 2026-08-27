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

# A notification gets no reply at all, so exactly the seven requests with an id answer.
check("no reply to a notification", len(seen) == 7)

d = result("d")
check("discover names the current revision", d.get("supportedVersions", [None])[0] == "2026-07-28")
check("discover carries resultType", d.get("resultType") == "complete")
check("discover is cacheable", "ttlMs" in d and d.get("cacheScope") in ("public", "private"))
check("discover identifies the server",
      d.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {}).get("name") == "pdf-hammer")

i = result("1")
check("the legacy handshake agrees on the asked-for version",
      i.get("protocolVersion") == "2025-06-18")
check("the legacy handshake declares tools", "tools" in i.get("capabilities", {}))

t = result("2")
check("tools/list carries resultType and a cache hint",
      t.get("resultType") == "complete" and "ttlMs" in t)
check("every tool has a name and an object input schema",
      bool(t.get("tools")) and all(x["name"] and x["inputSchema"]["type"] == "object" for x in t["tools"]))
check("tool order is deterministic",
      [x["name"] for x in t.get("tools", [])] == [x["name"] for x in t.get("tools", [])])

c = result("3")
check("an empty folder is not an error", c.get("isError") is False)
check("a tool result carries resultType", c.get("resultType") == "complete")

check("an unknown tool is a protocol error", seen.get("4", {}).get("error", {}).get("code") == -32602)
check("a tool that cannot do the job answers with isError, not an error",
      result("5").get("isError") is True)
check("an unsupported protocol version is refused with -32022",
      seen.get("6", {}).get("error", {}).get("code") == -32022)

sys.exit(1 if check.failed else 0)
