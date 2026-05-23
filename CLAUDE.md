# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project (document hierarchy, repository structure, processes, conventions, pre-merge checklists). Everything in `AGENTS.md` applies to Claude.

This file adds Claude-specific lessons that complement `AGENTS.md`.

## Verifying SDK and tool behavior

See `AGENTS.md` § Verifying SDK and Tool Behavior — the rules apply to Claude exactly as written. Verify library behavior against the pinned source before asserting; treat negative claims ("this rule doesn't exist," "this flag isn't supported") as needing empirical verification before they become "remove this" recommendations.

For BSD/GNU CLI portability when verifying local changes (`stat`, `sed -i`, `date -r`, etc.) before claiming green, see `AGENTS.md` § Verifying Local Changes Before Claiming Green.

## Posting review content to GitHub

For review writeups, retrospectives, and manual-test plans, use the `gh pr comment` plus temporary-file pattern documented in `AGENTS.md` § GitHub PR Publishing Notes. Do not commit review artifacts to the repo root; keep PR discussion inside the PR so the next reader has the full thread in one place.

Before posting any GitHub comment or PR description, scan for tokens GitHub auto-resolves: `#N` becomes a cross-reference to a PR/issue in this repo, `@user` notifies, bare GitHub URLs unfurl. Use distinct prefixes for review-finding labels across rounds (`F1`-`Fn` for initial findings, `T1`-`Tn` for test follow-ups, etc.) so inline references unambiguously target one round and don't collide with GitHub's `#N` syntax. If a comment already posted contains a collision, edit it in place via `gh api PATCH /repos/<owner>/<repo>/issues/comments/<id>` rather than reposting.

Every PR comment or PR description Claude posts must start with a short italic attribution line on its own at the very top, before any heading or other content: `_Posted by Claude Code_`. This makes Claude's comments distinguishable from Ivan's direct comments and Codex's comments — all three post under the same GitHub account, and the attribution is the only way a future reader can tell them apart. Keep the line role-agnostic; Claude may act as reviewer, implementer, debugger, or planner depending on the task.

Inline review threads on a PR cannot be resolved via REST. Use the GraphQL `resolveReviewThread` mutation with the thread's node ID (which is different from the comment ID returned by REST). Fetch IDs first with `gh api graphql -f query='query{ repository(owner:"<owner>",name:"<repo>"){ pullRequest(number:<n>){ reviewThreads(first:20){ nodes{ id isResolved comments(first:1){ nodes{ path body } } } } } } }'`, then resolve each with `gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -F id=<thread_node_id>`. Resolve only after the addressed fix is committed and pushed on the PR's head. For deferred items, post a brief reply on the thread before resolving that names where the deferred work was captured — silently resolving a deferred thread loses the audit trail for future readers landing on the PR.
