# CatVox Local AI Loop

This directory contains the local AI loop for Option B from ADR-0023.

Slice 1 created committed loop logs and dry-run routing. Slice 2 adds
role-aware prompt composition and optional local agent invocation for Codex and
Claude Code. Invocation remains opt-in so developers can validate routing
without spending tokens or giving a local CLI write access by accident.

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

This creates or switches to `AI_LOOP_BRANCH`, writes a committed bootstrap log
under:

```text
docs/ai-loop/local-YYYYMMDD-HHMMSS.md
```

and commits it with:

```text
[ai-loop] Human: start <run_id>
```

The `post-commit` hook then wakes the controller and prints a dry-run routing
decision. To let the hook dispatch the routed local agent, opt in explicitly:

```bash
AI_LOOP_INVOKE_AGENTS=1 make ai-loop-start \
  AI_LOOP_BRANCH=feature/example \
  AI_LOOP_PROMPT="Implement the requested change"
```

You can also enable invocation for this clone:

```bash
git config ai-loop.invokeAgents true
```

Disable it with:

```bash
git config --unset ai-loop.invokeAgents
```

Manual dispatch for the latest `[ai-loop]` commit is also available:

```bash
python3 tools/ai-loop/ai_loop.py continue --invoke --trigger manual
```

Use `--dry-run` to force observe-only routing even when invocation is enabled.

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

## Agent Invocation Context

Agent prompts include a verified manifest of repository instruction files before
task context. The files are referenced by path rather than inlined, so local
agent calls stay small while still making the required process instructions
explicit. Do not rely only on each CLI's automatic discovery behavior.

Required context for every agent:

- `AGENTS.md`
- `tools/ai-loop/prompts/common.md`
- the current AI loop log
- current Git status and relevant diff context

Required extra context by role:

- Codex developer: `.codex/AGENTS.md` and `tools/ai-loop/prompts/developer.md`
- Claude reviewer: `CLAUDE.md` and `tools/ai-loop/prompts/reviewer.md`

The prompt order is:

1. instruction file manifest:
   `AGENTS.md`, the role-specific overlay, common AI-loop prompt, and
   role-specific AI-loop prompt
2. task context: current loop log path and compact state, Git status, base/head
   SHAs, changed-file summary, and diff-stat summary

If a CLI invocation cannot include those files reliably, the orchestrator must
stop before dispatching the agent rather than run with incomplete process
instructions.

The prompt does not inline the full branch patch. Agents receive the resolved
diff range and suggested commands such as `git diff <base>..<head>` and
path-scoped diffs, then inspect only the details they need locally.

To inspect a prompt without invoking an agent:

```bash
python3 tools/ai-loop/ai_loop.py compose-prompt \
  --role reviewer \
  --log docs/ai-loop/local-YYYYMMDD-HHMMSS.md
```

Default local commands:

```text
Codex developer:  codex exec --cd <repo> -
Claude reviewer:  claude --print --input-format text
```

Both commands receive the composed prompt on stdin. For local experimentation,
override them with `AI_LOOP_CODEX_COMMAND` or `AI_LOOP_CLAUDE_COMMAND`.

## Slice 2 Limitations

- Agent invocation is opt-in; default hook behavior remains dry-run.
- The controller dispatches only the single routed agent for the latest event.
  Full automatic multi-cycle developer/reviewer looping is deferred.
- No draft PR creation.
- No `docs/ai-loop/pr-XXXX.md` bootstrap yet.
- No human answer command yet.

ADR-0023 requires committed PR-numbered loop logs for the MVP. The current
implementation still uses a local run ID first so parser, hook, routing, and
invocation behavior can be validated before PR-number bootstrap is added.
