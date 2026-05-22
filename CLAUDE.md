# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project (document hierarchy, repository structure, processes, conventions, pre-merge checklists). Everything in `AGENTS.md` applies to Claude.

This file adds Claude-specific lessons that complement `AGENTS.md`.

## PR review workflow

Open every review with a one-sentence "is this PR right-sized for the bug it claims to fix?" check. Catching scope creep before drilling into findings saves review rounds, and the answer informs the depth of the rest of the review.

When a review round prompts scope expansion that no longer matches the PR title, parent-issue link, or slice framing, ask explicitly whether to reframe — update the PR title, change the issue cross-reference, or retitle the slice. Right-sizing as observation is weaker than right-sizing as action; if the scope has genuinely shifted, the framing should shift with it.

Use severity gating (High / Medium / Low / Observations) with explicit "block on" vs "nice to have" labels. Numbering every nit at Low severity inflates the punch list — cluster sub-low items under a single "Nits" heading rather than giving each its own ID. If a Low or Observation item needs hedging in the chat preview ("borderline", "arguably", "could go either way"), drop it instead of clustering — the clustering rule applies to nits you'd post unconditionally; hedged items add review noise without adding signal.

When two docs, config files, or build settings name what looks like the same thing differently, trace each name to what it actually points to in code/config before drafting a "pick one" finding. In layered build systems (xcconfig keys, build-setting passthrough, Info.plist values, runtime env-var overrides), the same conceptual value often has multiple correct names at different layers — for example, an xcconfig key like `*_HOST_NAME` that stores hostname only, alongside a runtime env-var override like `*_HOST` that expects a full URL. The first move on a naming disagreement is reconstruction, not arbitration.

When the developer's revision improves on your suggestion (for example, splitting one error case into two semantically distinct cases rather than the tagged-source variant you proposed), call it out explicitly in the next round. Credit the thinking, not just the diff.

For substantive PR reviews, the PR comment thread is the source of truth — Codex (or the next reviewer) picks up findings there. Post structured findings, verification tables, and follow-ups to `gh pr comment`, not chat. Chat is for the user's decisions and opinions; the chat reply after posting should be a one-line link to the PR comment, not a duplicate of the findings.

When a review surfaces a safety, security, or auth boundary (mutation gates, env-aware checks, predicate functions), bundle a "make this unit-testable" structural suggestion into the same finding — typically: extract the gate as a pure function with explicit inputs. A boundary verifiable only by aiming at the production system is a boundary that won't be verified.

When recommending a "fail loud" or stricter validation change, enumerate the failure modes you expect to be caught — empty, whitespace-only, scheme-only, wrong scheme, and so on — rather than naming one example. A reviewer who specifies only one example forces the developer to infer the rest; missed modes return as follow-up findings.

When a PR introduces shared infrastructure (Terraform modules, library helpers, base config, abstractions designed to be reused across environments) that the immediate change uses for one environment but future changes will reuse for others, run a "Prod-safety regression risk" pass before settling on findings. Scan for defaults baked into shared code that are fine for the immediate use case (e.g. Dev) but unsafe in the broader use case the code will eventually serve (e.g. Prod). Default values, deletion policies, debug flags, error-recovery behavior, and "convenience" fallbacks are the usual culprits. The lens: if this code were used unchanged for the most stringent environment it's meant to serve, what would break?

When posting verification of fixes, explicitly distinguish what was checked by reading code, by running tests, or by visual inspection, from what was trusted via the developer's claim. Status tables without this disclosure read as exhaustive when parts of the claim were not independently verified.

When recommending test additions, include an explicit "not worth adding" list. Test-coverage prompts without an explicit non-goals list reliably trigger sprawl — call out what's already covered by integration tests, what's framework/platform behavior, and what's trivial composition the suite would re-verify for no gain.

For iOS App Check, Firebase, or async/state-related findings, follow the failure-source classification and Release-leak audit already documented in `AGENTS.md`.

## Verifying SDK and tool behavior

See `AGENTS.md` § Verifying SDK and Tool Behavior — the rules apply to Claude exactly as written. Verify library behavior against the pinned source before asserting; treat negative claims ("this rule doesn't exist," "this flag isn't supported") as needing empirical verification before they become "remove this" recommendations.

## Posting review content to GitHub

For review writeups, retrospectives, and manual-test plans, use the `gh pr comment` plus temporary-file pattern documented in `AGENTS.md` § GitHub PR Publishing Notes. Do not commit review artifacts to the repo root; keep PR discussion inside the PR so the next reader has the full thread in one place.

Before posting any GitHub comment or PR description, scan for tokens GitHub auto-resolves: `#N` becomes a cross-reference to a PR/issue in this repo, `@user` notifies, bare GitHub URLs unfurl. Use distinct prefixes for review-finding labels across rounds (`F1`-`Fn` for initial findings, `T1`-`Tn` for test follow-ups, etc.) so inline references unambiguously target one round and don't collide with GitHub's `#N` syntax. If a comment already posted contains a collision, edit it in place via `gh api PATCH /repos/<owner>/<repo>/issues/comments/<id>` rather than reposting.

Every PR comment or PR description Claude posts must start with a short italic attribution line on its own at the very top, before any heading or other content: `_Posted by Claude Code_`. This makes Claude's comments distinguishable from Ivan's direct comments and Codex's comments — all three post under the same GitHub account, and the attribution is the only way a future reader can tell them apart. Keep the line role-agnostic; Claude may act as reviewer, implementer, debugger, or planner depending on the task.

Inline review threads on a PR cannot be resolved via REST. Use the GraphQL `resolveReviewThread` mutation with the thread's node ID (which is different from the comment ID returned by REST). Fetch IDs first with `gh api graphql -f query='query{ repository(owner:"<owner>",name:"<repo>"){ pullRequest(number:<n>){ reviewThreads(first:20){ nodes{ id isResolved comments(first:1){ nodes{ path body } } } } } } }'`, then resolve each with `gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -F id=<thread_node_id>`. Resolve only after the addressed fix is committed and pushed on the PR's head. For deferred items, post a brief reply on the thread before resolving that names where the deferred work was captured — silently resolving a deferred thread loses the audit trail for future readers landing on the PR.
