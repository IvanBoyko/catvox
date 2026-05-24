# AI Loop Common Instructions

You are participating in the CatVox local AI implementation/review loop.

## Shared Rules

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

Slice 1 only creates and parses this format. Real agent invocation is deferred.
