# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project (document hierarchy, repository structure, processes, conventions, pre-merge checklists). Everything in `AGENTS.md` applies to Claude.

This file adds Claude-specific lessons that complement `AGENTS.md`.

## Verifying SDK and tool behavior

See `AGENTS.md` § Verifying SDK and Tool Behavior — the rules apply to Claude exactly as written. Verify library behavior against the pinned source before asserting; treat negative claims ("this rule doesn't exist," "this flag isn't supported") as needing empirical verification before they become "remove this" recommendations.

For BSD/GNU CLI portability when verifying local changes (`stat`, `sed -i`, `date -r`, etc.) before claiming green, see `AGENTS.md` § Verifying Local Changes Before Claiming Green.

## Attribution on GitHub comments

Every PR comment or PR description Claude posts must start with a short italic attribution line on its own at the very top, before any heading or other content: `_Posted by Claude Code_`. This makes Claude's comments distinguishable from Ivan's direct comments and Codex's comments — all three post under the same GitHub account, and the attribution is the only way a future reader can tell them apart. Keep the line role-agnostic; Claude may act as reviewer, implementer, debugger, or planner depending on the task.

For everything else about posting to GitHub — temporary body files, auto-resolved tokens like `#N` and `@user`, finding-ID numbering across rounds, and resolving inline review threads via GraphQL — see `AGENTS.md` § GitHub PR Publishing Notes.
