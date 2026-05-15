# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project (document hierarchy, repository structure, processes, conventions, pre-merge checklists). Everything in `AGENTS.md` applies to Claude.

This file adds Claude-specific lessons that complement `AGENTS.md`.

## PR review workflow

Open every review with a one-sentence "is this PR right-sized for the bug it claims to fix?" check. Catching scope creep before drilling into findings saves review rounds, and the answer informs the depth of the rest of the review.

Use severity gating (High / Medium / Low / Observations) with explicit "block on" vs "nice to have" labels. Numbering every nit at Low severity inflates the punch list — cluster sub-low items under a single "Nits" heading rather than giving each its own ID.

When the developer's revision improves on your suggestion (for example, splitting one error case into two semantically distinct cases rather than the tagged-source variant you proposed), call it out explicitly in the next round. Credit the thinking, not just the diff.

For iOS App Check, Firebase, or async/state-related findings, follow the failure-source classification and Release-leak audit already documented in `AGENTS.md`.

## Verifying SDK behavior

For questions about third-party SDK runtime behavior (Firebase, Apple frameworks, etc.), read the pinned source instead of recalling from memory or public docs:

- iOS SwiftPM: `.build/ios-device/SourcePackages/checkouts/<sdk>/...`

That source is what the linked binary actually does — public docs may lag or describe a different version. Do not assert SDK env-var names, error domains, caching, or thread-safety without verifying against the pinned source first.

## Posting review content to GitHub

For review writeups, retrospectives, and manual-test plans, use the `gh pr comment` plus temporary-file pattern documented in `AGENTS.md` § GitHub PR Publishing Notes. Do not commit review artifacts to the repo root; keep PR discussion inside the PR so the next reader has the full thread in one place.
