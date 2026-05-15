# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project (document hierarchy, repository structure, processes, conventions, pre-merge checklists). Everything in `AGENTS.md` applies to Claude.

This file adds Claude-specific lessons that complement `AGENTS.md`.

## PR review workflow

Open every review with a one-sentence "is this PR right-sized for the bug it claims to fix?" check. Catching scope creep before drilling into findings saves review rounds, and the answer informs the depth of the rest of the review.

Use severity gating (High / Medium / Low / Observations) with explicit "block on" vs "nice to have" labels. Numbering every nit at Low severity inflates the punch list — cluster sub-low items under a single "Nits" heading rather than giving each its own ID.

When the developer's revision improves on your suggestion (for example, splitting one error case into two semantically distinct cases rather than the tagged-source variant you proposed), call it out explicitly in the next round. Credit the thinking, not just the diff.

For substantive PR reviews, the PR comment thread is the source of truth — Codex (or the next reviewer) picks up findings there. Post structured findings, verification tables, and follow-ups to `gh pr comment`, not chat. Chat is for the user's decisions and opinions; the chat reply after posting should be a one-line link to the PR comment, not a duplicate of the findings.

When a review surfaces a safety, security, or auth boundary (mutation gates, env-aware checks, predicate functions), bundle a "make this unit-testable" structural suggestion into the same finding — typically: extract the gate as a pure function with explicit inputs. A boundary verifiable only by aiming at the production system is a boundary that won't be verified.

When posting verification of fixes, explicitly distinguish what was checked by reading code, by running tests, or by visual inspection, from what was trusted via the developer's claim. Status tables without this disclosure read as exhaustive when parts of the claim were not independently verified.

When recommending test additions, include an explicit "not worth adding" list. Test-coverage prompts without an explicit non-goals list reliably trigger sprawl — call out what's already covered by integration tests, what's framework/platform behavior, and what's trivial composition the suite would re-verify for no gain.

For iOS App Check, Firebase, or async/state-related findings, follow the failure-source classification and Release-leak audit already documented in `AGENTS.md`.

## Verifying SDK behavior

For questions about third-party SDK runtime behavior (Firebase, Apple frameworks, etc.), read the pinned source instead of recalling from memory or public docs:

- iOS SwiftPM: `.build/ios-device/SourcePackages/checkouts/<sdk>/...`

That source is what the linked binary actually does — public docs may lag or describe a different version. Do not assert SDK env-var names, error domains, caching, or thread-safety without verifying against the pinned source first.

## Posting review content to GitHub

For review writeups, retrospectives, and manual-test plans, use the `gh pr comment` plus temporary-file pattern documented in `AGENTS.md` § GitHub PR Publishing Notes. Do not commit review artifacts to the repo root; keep PR discussion inside the PR so the next reader has the full thread in one place.

Before posting any GitHub comment or PR description, scan for tokens GitHub auto-resolves: `#N` becomes a cross-reference to a PR/issue in this repo, `@user` notifies, bare GitHub URLs unfurl. Use distinct prefixes for review-finding labels across rounds (`F1`-`Fn` for initial findings, `T1`-`Tn` for test follow-ups, etc.) so inline references unambiguously target one round and don't collide with GitHub's `#N` syntax. If a comment already posted contains a collision, edit it in place via `gh api PATCH /repos/<owner>/<repo>/issues/comments/<id>` rather than reposting.
