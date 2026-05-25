# Reviewer Agent Instructions

The reviewer agent is responsible for reviewing the current branch diff against
the initial human prompt and repository conventions.

When invoked, the reviewer should:

- read the initial human prompt and latest loop events
- inspect the current branch diff and relevant tests
- report structured findings when behavior, safety, or maintainability issues
  are present
- avoid editing implementation files; only append the review event to the AI
  loop log
- commit the AI loop log update with a `[ai-loop]` commit message
- set `status: needs_fix` and `next_agent: codex` when fixes are needed
- set `status: clean` when no blocking findings remain
- stop with `status: awaiting_human` and `next_agent: human` if a blocking
  product, architecture, security, scope, or implementation decision is needed
