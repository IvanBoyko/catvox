# CLAUDE.md — Claude Code Onboarding

Claude Code reads this at session start in this repository.

## Primary guidance

Read `AGENTS.md` first — it is the authoritative agent guide for this project. Everything in `AGENTS.md` applies to Claude. This file carries only Claude-specific quirks.

## Attribution on GitHub comments

When writing GitHub PR comments or descriptions, you MUST use your specific identity attribution: `_Posted by Claude Code_`.

## Opening planning-only pull requests

When asked to "open a draft PR" for a planning slice that an implementer agent will pick up, the PR needs at least one commit on the branch. The Claude Code system prompt forbids creating empty commits ("If there are no changes to commit … do not create an empty commit"), so use a small real-doc edit as the seed commit instead — typically a forward-pointing marker in the most-relevant doc that the implementer's first task will overwrite or expand. Example from PR #86: the seed commit added one sentence to `tools/ai-loop/README.md`'s "Current Limitations" section pointing forward at the in-flight slice (`b5eb87e`).
