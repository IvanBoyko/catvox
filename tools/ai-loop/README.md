# CatVox Local AI Loop

This directory contains the local AI loop scaffold for Option B from ADR-0023.
Slice 1 creates committed loop logs and dry-run routing only. It does not invoke
Codex, Claude Code, Gemini, or any other agent.

## Setup

Run once per clone:

```bash
make setup-local-ai-loop
```

This configures:

```bash
git config core.hooksPath tools/ai-loop/hooks
```

The hook is repository-controlled, but the Git setting is local to each clone.

## Start A Local Run

```bash
make ai-loop-start \
  AI_LOOP_BRANCH=feature/example \
  AI_LOOP_PROMPT="Implement the requested change"
```

Slice 1 creates or switches to `AI_LOOP_BRANCH`, writes a committed bootstrap log
under:

```text
docs/ai-loop/local-YYYYMMDD-HHMMSS.md
```

and commits it with:

```text
[ai-loop] Human: start <run_id>
```

The `post-commit` hook then wakes the controller and prints a dry-run routing
decision.

## Metadata Format

Machine-readable state lives in HTML comment blocks with key-value lines:

```markdown
<!-- ai-loop-event
agent: human
role: owner
cycle: 0
status: needs_developer
next_agent: codex
-->
```

Current state is derived from the latest `ai-loop-event` block.

## Slice 1 Limitations

- No real agent invocation.
- No draft PR creation.
- No `docs/ai-loop/pr-XXXX.md` bootstrap yet.
- No human answer command yet.

ADR-0023 requires committed PR-numbered loop logs for the MVP. Slice 1 uses a
local run ID first so the parser, hook, and dry-run routing can be validated
before the PR-number bootstrap is added.
