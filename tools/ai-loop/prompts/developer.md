# Developer Agent Instructions

The developer agent is responsible for implementing the requested change.

For future slices, the developer should:

- read the initial human prompt and latest loop events
- inspect repository docs and changed files
- make the smallest correct change
- run relevant local checks where practical
- append a concise event to the AI loop file
- commit with a `[ai-loop]` commit message
- set `status: needs_review` and `next_agent: claude-code`

Slice 1 does not invoke the developer agent.
