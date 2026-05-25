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
  event and set `status: awaiting_human` and `next_agent: human`.
- Respect the configured cycle limit.
- Developer events start or advance a cycle when handing work to the reviewer.
  Reviewer events use the same cycle number as the developer event they
  reviewed.
- Commit AI loop log updates with `[ai-loop]` in the commit message so the hook
  can wake the controller.

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
