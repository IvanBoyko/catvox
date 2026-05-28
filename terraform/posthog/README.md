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

## Slice scope

This root manages the `CatVox <Environment>` PostHog project, the
"Analytics basics" dashboard, its dashboard layout, and 5 wizard-created
insights (issue #37 Slice 4). The HCL mirrors the live wizard configuration
verbatim — including the deliberately-mis-labelled "Share sheet" series on
`scan_share_actions` that uses `scan_shared` instead of `share_sheet_opened`.
Slice 5 will rewrite share semantics and normalise tile ordering for shared
Dev/Prod reuse; Slice 4 only captures current state with zero drift.

## Replaying the import in a new environment

When future Prod GCP provisioning unblocks the Prod PostHog state bucket, the
same HCL covers Prod with three steps — no code changes:

1. Resolve the wizard insight short IDs to numeric IDs by querying the PostHog
   API. With `POSTHOG_API_KEY` scoped to the target project (read-only is
   sufficient):

   ```bash
   for sid in HpsroXVQ 3ZD4bnzS kB5Hjls2 brptiNF5 5dK5T6k9; do
     curl -sS -H "Authorization: Bearer $POSTHOG_API_KEY" \
       "https://us.posthog.com/api/projects/<project_id>/insights/?short_id=$sid" \
     | jq -r --arg sid "$sid" '.results[0] | "\($sid)\t\(.id)\t\(.name)"'
   done
   ```

2. Update the literal numeric IDs in `insights.tf` (the `import { id = ... }`
   blocks) and the dashboard ID in `dashboard.tf` to match the new
   environment's wizard-created resources.

3. Run `make posthog-terraform-plan CATVOX_ENVIRONMENT=<env>`. Triage any
   drift by adjusting HCL field values to mirror server state; the goal is a
   zero-change plan before merging.

The `import {}` blocks are intentionally left in source after first apply.
Terraform skips them on subsequent runs once state already contains the
target resource, so they double as durable documentation of where each
resource originated. They may be removed in a later cleanup PR once the
import history is no longer load-bearing.
