# ADR-0023: Adopt Hybrid Agent Review Loop

- Status: Accepted
- Date: 2026-05-24
- Owners: Kathelix / CatVox
- Related issue: GitHub Issue 63
- Related docs: `AGENTS.md`, `.codex/AGENTS.md`, `CLAUDE.md`, `.antigravityrules`, `Makefile`

## Context

CatVox development currently uses an iterative propose, implement, review, and
verify loop between AI developer agents, AI reviewer agents, and Ivan. The loop
works, but it is manually orchestrated. Ivan has to start each agent turn,
transfer findings between tools, and decide when the next reviewer or developer
should run.

GitHub Issue 63 compared three possible automation models:

- Option A: GitHub Actions orchestrates the review loop through PR comments,
  labels, and agent actions.
- Option B: a local orchestrator on the developer machine coordinates local AI
  agents and keeps the early implementation loop outside the PR thread.
- Option C: LangGraph owns the workflow as a dedicated state-machine framework.

Option A is portable and cloud-native, and current provider tooling makes it
feasible. OpenAI Codex, Claude Code, and Gemini all have headless or automation
paths that can participate in CI-hosted workflows.

However, the highest current pain is not only the final review handoff. It is
the early PR stage, where architectural discussion, scope shaping, and human
clarification happen quickly in local Codex and Claude chats. Moving that whole
conversation into PR comments would make the loop slower and would add durable
noise to the PR. Option A also expands the security surface because CI-hosted
agents would consume PR-controlled text and diffs while using provider secrets.

Option B better matches the current pain: keep the exploratory loop local and
fast, then publish a cleaner PR for durable review. Option C may become useful
later, but it adds a framework and persistence model before the simpler local
state machine has proven insufficient.

## Decision

CatVox will adopt a hybrid agent review architecture:

1. The near-term MVP is Option B: a local agent loop is the first stage of task
   implementation.
2. Option A may be added later as an opt-in GitHub Actions reviewer pass after
   the local loop has converged.
3. Option C / LangGraph is deferred until the local orchestrator becomes too
   complex or the workflow needs durable multi-repository orchestration, a UI,
   or richer pause/resume semantics.

The Option B local loop should use a purpose-built controller, initially a small
Python script under `tools/ai-loop/`. The Git hook, if used, is only a wake-up
trigger. It must not contain orchestration logic. The repository `Makefile`
remains a thin facade for setup and user-facing commands, consistent with
ADR-0014.

The local orchestrator owns workflow state and transitions. It should model at
least these states:

- needs review
- needs fix
- clean
- awaiting human
- failed
- max cycles reached

Human clarification is a first-class stop condition. Agents must not guess on
blocking product, architecture, security, scope, or implementation decisions.
When clarification is needed, the loop stops and asks all independent blocking
questions together. The human answer resumes the local loop.

Detailed AI-to-AI discussion is local by default. The final PR should carry a
concise summary of the important decisions, implementation, validation, and
remaining risks. A detailed loop log may be committed only when explicitly
useful for traceability; it must not be automatic PR noise.

Option A, when implemented later, must be opt-in, for example by label. It is a
reviewer augmentation layer, not the primary exploratory design channel. It must
preserve human-only merge, stop on human clarification, avoid untrusted fork
secret exposure, and use strict safeguards for provider credentials and
PR-controlled input.

## Consequences

- Early architectural discussion and human clarification stay fast and local.
- PRs should become cleaner because the PR thread is no longer the scratchpad
  for the whole AI-to-AI iteration loop.
- The local loop has more setup cost than a pure GitHub Actions workflow. New
  developers must run an explicit setup command and have the required local AI
  CLIs authenticated.
- The first implementation slices should verify local headless agent invocation
  before building deeper orchestration around it.
- The local orchestrator must handle locks, dirty working trees, branch safety,
  cycle limits, and stale or failed agent runs deliberately.
- A future GitHub Actions reviewer pass can still improve independent review
  coverage, but it should run after the local loop has produced a focused PR.
- LangGraph remains available as a future refactor path if the custom local
  state machine becomes a maintenance burden.

## Documentation Follow-up

This ADR records the workflow architecture decision. HLD and TRD do not need
product-behavior updates for this change.

Implementation PRs for the local loop should add or update:

- `AGENTS.md` for cross-agent workflow conventions
- `.codex/AGENTS.md`, `CLAUDE.md`, and `.antigravityrules` if agent-specific
  behavior is required
- a local loop runbook, likely under `tools/ai-loop/README.md` or
  `docs/AGENT_REVIEW_LOOP.md`
- `Makefile` help text and targets for any user-facing setup or loop commands

If a later Option A workflow is added under `.github/workflows/`, that PR should
also document its security gates, opt-in trigger, human clarification behavior,
and cost guardrails.
