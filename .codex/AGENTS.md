# Codex-Specific Instructions

This file supplements the root `AGENTS.md` with instructions specifically for Codex's sandbox and identity.

1. **Sandbox Environment Limits**: Simulator builds may fail inside the sandbox because of `CoreSimulatorService` and `~/Library` access. If that happens, rerun the same `xcodebuild` command outside the sandbox instead of changing the build command.
2. **Identity in PR Comments**: When writing GitHub PR comments or descriptions, you MUST use your specific identity attribution: `_Posted by Codex_`.
