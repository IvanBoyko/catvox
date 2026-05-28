# PostHog Terraform Root

This Terraform root manages PostHog projects, dashboards, and insights for one
CatVox environment at a time. PostHog environments map 1:1 to CatVox
environments — see ADR-0019, ADR-0020, and ADR-0021.

## State

State lives in the same GCS bucket as the matching environment's GCP
infrastructure state, with prefix `posthog/state`:

| CatVox env | State bucket | Prefix |
|---|---|---|
| `dev` | `catvox-tf-state-kathelix-catvox-dev` | `posthog/state` |
| `prod` (future) | `catvox-tf-state-kathelix-catvox-prod` | `posthog/state` |

There is no separate state bucket for PostHog. The existing per-environment
`catvox-ci-sa` already has `storage.objectAdmin` on its environment's state
bucket, so adding a second prefix requires no IAM changes.

## Per-environment values

Per-environment values come from two places:

- `config/environments/<env>.xcconfig` for non-secret values such as
  `CATVOX_ENVIRONMENT`, `CATVOX_POSTHOG_API_HOST_NAME`,
  `CATVOX_POSTHOG_PROJECT_ID`, and `CATVOX_POSTHOG_ORGANIZATION_ID`. The
  Makefile reads these via `scripts/lib/read-xcconfig-value.sh`, exports them as
  `TF_VAR_*`, and configures the PostHog provider host, project default, and
  organization default from those values.
- The matching per-environment GitHub Environment for secrets and tokens such
  as `POSTHOG_API_KEY`. The CI workflow exports this as a provider environment
  variable.

There is no `terraform/posthog/env/<env>.tfvars` directory. The xcconfig file
is the authoritative environment definition. See ADR-0020 and ADR-0021 for the
rationale.

## Local flow

```bash
# Export PostHog credentials for the provider before running plan/apply.
# Use a scoped API key limited to your environment's PostHog project.
export POSTHOG_API_KEY=...

make posthog-terraform-plan CATVOX_ENVIRONMENT=dev
```

`make posthog-terraform-apply CONFIRM=apply CATVOX_ENVIRONMENT=dev` runs
plan and apply interactively.

## CI flow

The `.github/workflows/posthog-terraform.yml` workflow runs `plan` on PRs that
touch `terraform/posthog/**`, `config/environments/**`, or the workflow itself,
and runs `apply` on push to `main`. It targets the `dev` GitHub Environment,
reads GCP auth identity from xcconfig, and reads the PostHog API key secret from
the GitHub Environment.

## Scope

This root manages the `CatVox <Environment>` PostHog project, the
"Analytics basics" dashboard, its dashboard layout, and 5 insights. The
insight definitions still reflect the original wizard choices — including the
mis-labelled "Share sheet" series on `scan_share_actions` that uses
`scan_shared` instead of `share_sheet_opened`. Slice 5 will rewrite share
semantics and normalise tile ordering so the same definitions cover every
environment with the corrected event taxonomy.

## Provisioning a new environment

Terraform is the source of truth — new environments are provisioned by
`terraform apply` against fresh per-environment state, which creates the
project, dashboard, layout, and insights directly from the HCL in this root.
No PostHog UI clicks, no wizard, no import. Sequence:

1. Bootstrap the new environment's GCP/Firebase foundation and the
   `posthog/state` prefix in its state bucket — covered by
   `docs/CREATE_NEW_ENVIRONMENT.md`.
2. Make sure `config/environments/<env>.xcconfig` carries the new
   environment's `CATVOX_POSTHOG_API_HOST_NAME` and
   `CATVOX_POSTHOG_ORGANIZATION_ID`. `CATVOX_POSTHOG_PROJECT_ID` and
   `CATVOX_POSTHOG_PROJECT_TOKEN` are populated *after* the first apply (see
   step 4).
3. Run `make posthog-terraform-plan CATVOX_ENVIRONMENT=<env>` with a
   `POSTHOG_API_KEY` scoped to the target organisation. Expected output:
   `Plan: 8 to add, 0 to change, 0 to destroy` — the project, dashboard,
   layout, and 5 insights.
4. Apply the plan. Read back the created project ID (`terraform output
   project_id`) and the project ingestion token (visible in the PostHog UI
   under Project Settings) and commit them into the matching
   `config/environments/<env>.xcconfig`. The token is the public ingestion
   key the iOS app sends events to; it is safe to commit by design.

The original Dev import (issue #37 Slice 4) used `import {}` blocks to adopt
the wizard-created Dev state; those blocks were removed after first apply.
No environment after Dev replays the import path.

## Drift triage gotchas

Three constraints in the PostHog provider (verified against
`PostHog/terraform-provider-posthog` v1.0.11 source) that decide whether the
first plan-after-import is zero-drift or has multiple iteration rounds. Check
each before writing HCL for a new replay:

1. **Strip server-injected fields from `posthog_insight.query_json`.** The
   provider's `Read` strips `version`, `result`, `hogql`, and `is_cached` from
   the API response before comparing against your HCL string. Mirror the
   stripped form, not the raw API response. Recipe:
   `jq -cS '.query | walk(if type == "object" then del(.version, .result, .hogql, .is_cached) else . end)'`.
2. **Match `posthog_dashboard_layout.tiles` to API order on first import.**
   The provider's `mapTilesToState` notes "Import case: return all tiles in
   API order." For empty-layout dashboards (no explicit positions set), the
   API order is descending `tile_id` (newest-first). HCL declared in a
   different order produces phantom diffs from positional `ListNestedAttribute`
   comparison. Re-ordering for narrative readability is a follow-up apply.
3. **Omit `layouts_json` for tiles with no explicit layout.** The provider's
   `apiTileToTFModel` checks `len(t.Layouts) > 0` and sets `LayoutsJSON` to
   null when false. HCL with `layouts_json = jsonencode({})` would produce
   drift on every plan; leave the field unset instead.
