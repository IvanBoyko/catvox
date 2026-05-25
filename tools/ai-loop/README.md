# CatVox Local AI Loop

This directory contains the local AI loop for Option B from ADR-0023.

Slice 1 created committed loop logs and dry-run routing. Slice 2 added
role-aware prompt composition and optional local agent invocation for Codex and
Claude Code. Slice 3 adds the first automatic reviewer handoff: when a
developer invocation commits a `needs_review` event, the controller dispatches
the reviewer once and then stops. Invocation remains opt-in so developers can
validate routing without spending tokens or giving a local CLI write access by
accident.

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

When a developer-routed agent commits a `needs_review` event, that event is
handed to Claude Code immediately. The reviewer may commit `clean`, `needs_fix`,
`awaiting_human`, or another stop-state event. The controller does not yet
dispatch the developer again after reviewer findings.

## Agent Profiles

Real local runs default to the `real` profile. Smoke tests can opt into the
cheaper `smoke` profile:

```bash
AI_LOOP_AGENT_PROFILE=smoke python3 tools/ai-loop/ai_loop.py continue --invoke
```

You can also set the local clone default:

```bash
git config ai-loop.agentProfile smoke
```

Profile selection order is:

1. `--agent-profile real|smoke`
2. `AI_LOOP_AGENT_PROFILE`
3. `git config ai-loop.agentProfile`
4. `real`

Built-in profile defaults:

| Agent | Profile | Default command behavior |
|---|---|---|
| Codex | `real` | `codex exec --cd <repo> -c model_reasoning_effort="xhigh" -` |
| Codex | `smoke` | `codex exec --cd <repo> -c model_reasoning_effort="low" -` |
| Claude Code | `real` | `claude --print --input-format text --model opus --effort max` |
| Claude Code | `smoke` | `claude --print --input-format text --model haiku --effort low` |

Pin exact local model names with:

```bash
AI_LOOP_CODEX_REAL_MODEL=...
AI_LOOP_CODEX_SMOKE_MODEL=...
AI_LOOP_CLAUDE_REAL_MODEL=...
AI_LOOP_CLAUDE_SMOKE_MODEL=...
```

For example, if the installed Claude CLI exposes exact model IDs for Opus 4.7
Max or Haiku 4.5, set `AI_LOOP_CLAUDE_REAL_MODEL` and
`AI_LOOP_CLAUDE_SMOKE_MODEL` to those exact strings.

Override effort independently with:

```bash
AI_LOOP_CODEX_REAL_EFFORT=xhigh
AI_LOOP_CODEX_SMOKE_EFFORT=low
AI_LOOP_CLAUDE_REAL_EFFORT=max
AI_LOOP_CLAUDE_SMOKE_EFFORT=low
```

Full command overrides remain available. Profile-specific overrides win over
legacy per-agent overrides:

```bash
AI_LOOP_CODEX_REAL_COMMAND="codex exec --cd {repo} --model gpt-5.5 -c 'model_reasoning_effort=\"xhigh\"' -"
AI_LOOP_CODEX_SMOKE_COMMAND="codex exec --cd {repo} -c 'model_reasoning_effort=\"low\"' -"
AI_LOOP_CLAUDE_REAL_COMMAND='claude --print --input-format text --model opus --effort max'
AI_LOOP_CLAUDE_SMOKE_COMMAND='claude --print --input-format text --model haiku --effort low'
```

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
- current Git status from `git status --short --branch`
- compact branch context

Required extra context by role:

- Codex developer: `.codex/AGENTS.md` and `tools/ai-loop/prompts/developer.md`
- Claude reviewer: `CLAUDE.md` and `tools/ai-loop/prompts/reviewer.md`

The prompt order is:

1. instruction file manifest:
   `AGENTS.md`, the role-specific overlay, common AI-loop prompt, and
   role-specific AI-loop prompt
2. task context: current loop log path and compact state, exact
   `git status --short --branch` output, resolved base ref, base ref SHA,
   merge-base SHA, dispatch HEAD SHA, changed-file summary, and diff-stat
   summary

If a CLI invocation cannot include those files reliably, the orchestrator must
stop before dispatching the agent rather than run with incomplete process
instructions.

The prompt does not inline the full branch patch by default. Agents receive the
resolved diff range and suggested local inspection commands, including:

```bash
git status --short --branch
git diff --stat <merge-base>..<head>
git diff --name-status <merge-base>..<head>
git diff <merge-base>..<head>
git diff <merge-base>..<head> -- <path>
```

Agents should inspect only the details they need locally. Before acting, the
agent must compare `git rev-parse HEAD` with the dispatch HEAD SHA in the
prompt. If they differ, the agent must stop and report stale state instead of
editing or reviewing.

To inspect a prompt without invoking an agent:

```bash
python3 tools/ai-loop/ai_loop.py compose-prompt \
  --role reviewer \
  --log docs/ai-loop/local-YYYYMMDD-HHMMSS.md
```

Profiled default local commands:

```text
Codex developer:  codex exec --cd <repo> -c model_reasoning_effort="<profile effort>" -
Claude reviewer:  claude --print --input-format text --model <profile model> --effort <profile effort>
```

Both commands receive the composed prompt on stdin. For local experimentation,
override them with profile-specific command variables or the legacy
`AI_LOOP_CODEX_COMMAND` / `AI_LOOP_CLAUDE_COMMAND` variables.

## Current Limitations

- Agent invocation is opt-in; default hook behavior remains dry-run.
- The controller supports only the first developer-to-reviewer handoff. Full
  automatic multi-cycle developer/reviewer looping is deferred.
- No draft PR creation.
- No `docs/ai-loop/pr-XXXX.md` bootstrap yet.
- No human answer command yet.

ADR-0023 requires committed PR-numbered loop logs for the MVP. The current
implementation still uses a local run ID first so parser, hook, routing, and
invocation behavior can be validated before PR-number bootstrap is added.
