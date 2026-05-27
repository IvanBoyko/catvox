# CatVox Local AI Loop

This directory contains the local AI loop for Option B from ADR-0023.

Slice 1 created committed loop logs and dry-run routing. Slice 2 added
role-aware prompt composition and optional local agent invocation for Codex and
Claude Code. Slice 3 added the first automatic reviewer handoff: when a
developer invocation commits a `needs_review` event, the controller dispatches
the reviewer once and then stops. Slice 4 adds human clarification answers:
when an agent stops with `awaiting_human`, `make ai-loop-answer` appends a
structured `clarified` event and wakes the controller to resume the asking
agent. Slice 5 adds the full bounded two-agent loop: the controller now routes
`needs_review` to the reviewer, `needs_fix` back to the developer, `clarified`
to the named supported agent, and stops on clean, blocked, failed, paused, or
cycle-cap states. Invocation remains opt-in so developers can validate routing
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

### Bootstrap A Draft PR (opt-in)

By default `make ai-loop-start` writes `docs/ai-loop/local-YYYYMMDD-HHMMSS.md`
and stops there — useful for offline iteration and dry-run validation. To
match the ADR-0023 MVP shape, opt in with `AI_LOOP_CREATE_PR=1`:

```bash
AI_LOOP_CREATE_PR=1 make ai-loop-start \
  AI_LOOP_BRANCH=feature/example \
  AI_LOOP_PROMPT="Implement the requested change"
```

When enabled, `start` then:

1. pushes the branch to `origin`
2. creates a draft PR with a placeholder `[wip] …` title and a minimal body
3. renames the bootstrap log to `docs/ai-loop/pr-NNNN.md` (zero-padded) and
   re-renders it with `pr:` metadata
4. commits the rename as `[ai-loop] Human: bootstrap pr-NNNN`
5. ensures the `ai-loop` repo label exists and applies it to the new PR

Agents are expected to keep the PR title and body current as the work
evolves via `gh pr edit` — see `tools/ai-loop/prompts/common.md`.

Enable PR creation for this clone:

```bash
git config ai-loop.createPr true
```

Disable with `git config --unset ai-loop.createPr`.

Bootstrap pre-flight refuses to proceed when any of the following is true,
leaving the local `[ai-loop] Human: start` commit intact so the run can be
resumed manually after the underlying issue is fixed:

- `gh` is not installed or not on `PATH`
- `gh auth status` fails (run `gh auth login`)
- the repository has no `origin` remote
- the current branch is not a descendant of `origin/main`
- an open PR already exists for the branch

When a developer-routed agent commits a `needs_review` event, that event is
handed to Claude Code immediately. When the reviewer commits `needs_fix`, the
controller dispatches Codex again. The loop repeats until the reviewer commits
`clean`, an agent asks for human clarification, a failure or pause state is
committed, or the configured max cycle count is reached. If cycle 3 is the
configured cap and the reviewer still commits `needs_fix`, the controller
commits a `max_cycles_reached` event instead of dispatching another developer
turn.

The cycle cap only fires on reviewer `needs_fix` → developer transitions. A
human `clarified` event that re-dispatches the asking agent is intentionally
**not** counted against `max_cycles`: answering a clarification question is the
human's way to grant the loop more runway, and the controller respects that.
Practically, a clarification round can extend execution past the configured cap
until the next reviewer `needs_fix` is committed at or above the cap. The
controller-side cycle accounting itself remains the responsibility of the
agents that emit `cycle:` metadata; see issue #84 for the broader hardening
plan to derive that count from log history instead.

## Answer Clarification

If an agent appends an `awaiting_human` event, answer through the helper instead
of editing the AI loop log manually:

```bash
make ai-loop-answer AI_LOOP_ANSWER="q1 A, q2 B - brief rationale"
```

The helper reads the latest AI loop log from `HEAD`, requires that the latest
event is `awaiting_human`, appends a human `clarified` event, and commits it
with:

```text
[ai-loop] Human: answer <question ids>
```

The hook then wakes the controller. By default it prints the dry-run routing
decision; with invocation enabled it dispatches the agent that asked the
clarification question. If the latest commit is not the relevant AI loop log,
pass it explicitly:

```bash
python3 tools/ai-loop/ai_loop.py answer \
  --log docs/ai-loop/local-YYYYMMDD-HHMMSS.md \
  --answer "q1 A"
```

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

Each local agent invocation has a timeout so a hung CLI cannot block the
controller indefinitely. The default is 1800 seconds. Override it per shell:

```bash
AI_LOOP_AGENT_TIMEOUT_SECONDS=900 python3 tools/ai-loop/ai_loop.py continue --invoke
```

Or set it for this clone:

```bash
git config ai-loop.agentTimeoutSeconds 900
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

## Extending Dispatch Chaining

The `post-commit` hook is a wake-up trigger, not the loop engine. While the
controller is running, it holds the `ai-loop.lock` directory. If a dispatched
agent commits another `[ai-loop]` event, the hook fires again but exits on that
lock. Any same-turn chaining must therefore happen in the still-running
controller process: verify `HEAD` advanced, verify the worktree is clean, read
the latest committed event, and dispatch the next role deliberately before
releasing the lock.

Keep dispatch output explicit. Dry-run routing may say `would dispatch`, but a
real chained handoff should print a flushed `dispatching ...` banner before
starting the subprocess so terminal and CI logs stay in causal order.

## Current Limitations

- Agent invocation is opt-in; default hook behavior remains dry-run.
- PR-numbered bootstrap is opt-in via `AI_LOOP_CREATE_PR=1`; the default
  remains the offline `docs/ai-loop/local-YYYYMMDD-HHMMSS.md` log.
- No end-of-loop PR description rewrite or telemetry yet — agents are expected
  to keep the PR title and body current themselves (see Slice 6 in
  Issue #63 for the planned controller-driven summary work).
