# PostHog Terraform Root

This Terraform root manages PostHog projects, dashboards, and insights for one
CatVox environment at a time. PostHog environments map 1:1 to CatVox
environments — see ADR-0019 and ADR-0020.

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
  `CATVOX_ENVIRONMENT` and `CATVOX_POSTHOG_PROJECT_ID`. The Makefile reads
  these via `scripts/lib/read-xcconfig-value.sh` and exports them as
  `TF_VAR_*` before invoking Terraform.
- The matching per-environment GitHub Environment for secrets and tokens such
  as `POSTHOG_API_KEY`, `POSTHOG_HOST`, `POSTHOG_ORGANIZATION_ID`, and
  `POSTHOG_PROJECT_ID`. The CI workflow exports these as `TF_VAR_*` and as
  provider environment variables.

There is no `terraform/posthog/env/<env>.tfvars` directory. The xcconfig file
is the authoritative environment definition. See ADR-0020 for the rationale.

## Local flow

```bash
cp terraform/posthog/backend/dev.hcl.example terraform/posthog/backend/dev.hcl

# Export PostHog credentials for the provider before running plan/apply.
# Use a scoped API key limited to your environment's PostHog project.
export POSTHOG_API_KEY=...
export POSTHOG_HOST=https://us.posthog.com
export POSTHOG_ORGANIZATION_ID=...

make posthog-terraform-plan CATVOX_TERRAFORM_ENV=dev
```

`make posthog-terraform-apply CONFIRM=apply CATVOX_TERRAFORM_ENV=dev` runs
plan and apply interactively.

## CI flow

The `.github/workflows/posthog-terraform.yml` workflow runs `plan` on PRs that
touch `terraform/posthog/**` or the workflow itself, and runs `apply` on push
to `main`. It targets the `dev` GitHub Environment and reads PostHog secrets
from there.

## Slice scope

This root currently declares no PostHog resources. Issue #37 Slice 4 imports
the existing `CatVox Dev` PostHog project and its wizard-created dashboard.
Slice 5 normalises dashboards as code so the same definitions cover both Dev
and Prod.
