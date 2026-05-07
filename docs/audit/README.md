# Repository Audits

This directory stores periodic repository audit reports produced by DeepSeek-TUI.

Run DeepSeek-TUI from the repository root with this prompt:

> Review the whole git repo, find obvious inconsistencies, bugs and issues, and output your numbered findings in markdown file `docs/audit/audit-2026-<MM>-<DD>.md`

Each audit file should keep numbered findings annotated with:

- `Status:` `Open`, `Resolved`, `Rejected`, or `Deferred`
- `Resolution:` a short note linking the fix, rejection rationale, or follow-up decision

When working on findings from these files, update both the relevant
`audit-2026-<MM>-<DD>.md` file and this README in the same change.

## Audit Files

- `audit-2026-05-07.md` - 1/19 resolved
