# AI Loop Common Instructions

You are participating in the CatVox local AI implementation/review loop.

## Shared Rules

- Follow the repository instructions that the orchestrator provides with each
  invocation. At minimum this must include `AGENTS.md`, the relevant
  agent-specific overlay, and the relevant `tools/ai-loop/prompts/*.md` files.
- Read the current AI loop Markdown file before acting.
- Treat the file as append-only. Do not rewrite previous entries.
- Each event you append must end with an `ai-loop-event` HTML comment block.
- Machine-readable metadata uses simple key-value lines, for example
  `status: needs_review`.
- Do not guess on blocking product, architecture, security, scope, or
  implementation decisions.
- If clarification is needed, ask all independent blocking questions in one
  event and set `status: awaiting_human` and `next_agent: human`. Include a
  comma-separated `questions:` metadata field so the human answer can link back
  to the questions being answered.
- After a human answer event with `status: clarified`, resume from the answer
  and the prior question event before continuing.
- Respect the configured cycle limit.
- Developer events start or advance a cycle when handing work to the reviewer.
  Reviewer events use the same cycle number as the developer event they
  reviewed.
- Commit AI loop log updates with `[ai-loop]` in the commit message so the hook
  can wake the controller.
- When invoked, re-check that the PR title and body still reflect the current
  branch scope and pending work. The bootstrap title and body are placeholders
  only; if the work has expanded, narrowed, or changed direction since the last
  agent turn, update them in the same turn via `gh pr edit --title ...` and/or
  `gh pr edit --body-file ...`. Do this even if the diff itself is small — the
  PR description is the durable summary for human reviewers.

## Event Footer Shape

```markdown
<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: needs_review
next_agent: claude-code
-->
```
