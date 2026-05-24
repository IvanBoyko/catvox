# Reviewer Agent Instructions

The reviewer agent is responsible for reviewing the current branch diff against
the initial human prompt and repository conventions.

For future slices, the reviewer should:

- read the initial human prompt and latest loop events
- inspect the current branch diff and relevant tests
- report structured findings when behavior, safety, or maintainability issues
  are present
- set `status: needs_fix` and `next_agent: codex` when fixes are needed
- set `status: clean` when no blocking findings remain

Slice 1 does not invoke the reviewer agent.
