# Codex-Specific Instructions

This file supplements the root `AGENTS.md` with instructions specifically for Codex's sandbox and identity.

1. **Sandbox Environment Limits**: Simulator builds may fail inside the sandbox because of `CoreSimulatorService` and `~/Library` access. If that happens, rerun the same `xcodebuild` command outside the sandbox instead of changing the build command.
2. **Identity in PR Comments**: When writing GitHub PR comments or descriptions, you MUST use your specific identity attribution: `_Posted by Codex_`.
3. **PR Review Handoffs**: When asked to review or verify a PR that another agent has continued, confirm the local checkout is on the PR branch and that `HEAD` matches the PR head SHA before running local verification. If the checkout is on `main`, stale, or otherwise mismatched, fetch/switch to the PR head first.
