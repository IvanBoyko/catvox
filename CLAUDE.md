# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project. Everything in `AGENTS.md` applies to Claude. This file carries only Claude-specific quirks.

## Attribution on GitHub comments

When writing GitHub PR comments or descriptions, you MUST use your specific identity attribution: `_Posted by Claude Code_`.

## Opening planning-only pull requests

When asked to "open a draft PR" for a planning slice that an implementer agent will pick up, the PR needs at least one commit on the branch. The Claude Code system prompt forbids creating empty commits ("If there are no changes to commit … do not create an empty commit"), so use a small real-doc edit as the seed commit instead — typically a forward-pointing marker in the most-relevant doc that the implementer's first task will overwrite or expand. Example from PR #86: the seed commit added one sentence to `tools/ai-loop/README.md`'s "Current Limitations" section pointing forward at the in-flight slice (`b5eb87e`).

## Driving a PR review loop (watch → fix → re-review)

When Ivan asks me to watch a PR's automated-reviewer loop and run review→fix→re-review to convergence, the cross-agent rules (post findings to the PR, consistency-sweep after rewiring, stop the watcher at the terminal state, never merge) live in `AGENTS.md`. Claude-Code-specific mechanics:

- **Prefer `/loop <interval>`** (e.g. `/loop 5m`) — the built-in recurring feature; it re-runs a prompt on the interval and I check the PR via `gh` each tick. No hand-written poll loop, so it avoids the trap below. (`/schedule` does the same on a cron expression; `ScheduleWakeup` is the single-timed-wake primitive.)
- **A `Monitor`** is the event-driven alternative (fires only on real new comments, no idle cost), but its poll loop runs under **zsh**, which does NOT word-split unquoted `$var`. A `for id in $ids` loop is a silent no-op there — the #118 review-watcher caught **0 of 7** rounds before it was reaped. Iterate with `while IFS= read -r id; do … done <<< "$ids"` and confirm at least one real event fires before trusting it.
- **Verify live state via `gh`; don't trust the watch event's payload.** The harness `<ci-monitor-event>` is noisy and sometimes stale (replays old comments, dumps `github-actions[bot]` plan-success spam, and once hid a genuinely-new round). Confirm against a watermark that there's a real `_Posted by Codex_`/`_Posted by Gemini_` comment newer than the last handled, check whether inline threads are still unresolved, and notice when HEAD moved from a human push.

The full playbook (and the auto-close-after-merge verification step) is captured durably in `AGENTS.md` and the agent's memory.
