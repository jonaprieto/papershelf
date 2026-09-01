# CLAUDE.md

Read `AGENTS.md` first. It holds the layout, the commands, the conventions, the invariants
that are easy to break, and the gotchas found the hard way. Everything there applies here;
this file only adds what is specific to working in Claude Code.

Guidance lives in one file on purpose. Two copies drift, and the stale one is always the one
somebody reads.

## Before changing behaviour

Run the thing rather than reasoning about it. This codebase has repeatedly rewarded that:

- The MCP server is drivable from a terminal with no GUI at all. Pipe newline-delimited
  JSON-RPC into `$(swift build --show-bin-path)/PaperShelfMCP` and read what comes back.
  Start with an `initialize` request, then one `tools/call` per line.
- `Sources/PaperShelfCore/Excerpt.swift` and the naming rules are pure functions. Copy the
  file into a scratch directory, compile it with a `main.swift` that calls it, and try real
  input. Several real defects here were found that way and would not have been found by
  reading.

## When a check passes

Ask whether it could fail. Revert the thing it covers and confirm it goes red. This repo has
shipped assertions that passed whether or not the feature worked: one asserted the absence of
a key the tool never emits, another verified SQLite's own auto-commit ordering rather than the
code under test. A green suite is evidence only to the extent its checks have teeth.

## Things not to do unattended

- Do not enable `mcpFileOperations`, and do not write to the `com.jonaprieto.pdfhammer`
  preferences domain. That setting gates real file moves on the user's disk. If a check would
  need it, describe the check and ask.
- Do not write into `~/Library/Application Support/PaperShelf/`. It holds the real library.
  Tests point at scratch paths through `PAPERSHELF_LIBRARY_PATH` and the plans-directory
  override; keep them pointing there.
- Do not launch the GUI app without saying so first. It takes focus on whichever Space is
  active, which interrupts whatever the user is doing.

## Working alongside the user

The user may be committing to the same branch at the same time. Before rebasing, amending, or
anything else that rewrites history, check `git status` and `git log` for work that is not
yours, and ask rather than stashing on their behalf. Uncommitted changes in the working tree
belong to them.
