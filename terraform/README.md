# Terraform Environment Conventions

CatVox's Terraform layout has three kinds of directories under `terraform/`:

| Path | Kind | Purpose |
|---|---|---|
| `terraform/` | Terraform root (GCP/Firebase foundation) | `.tf` files for GCP/Firebase infrastructure. State prefix `catvox/state`. CI workflow `.github/workflows/terraform.yml`. |
| `terraform/posthog/` | Terraform root (PostHog analytics) | `.tf` files for PostHog projects/dashboards/insights. State prefix `posthog/state`. CI workflow `.github/workflows/posthog-terraform.yml`. See `terraform/posthog/README.md` and ADR-0020. |
| `terraform/backend/`, `terraform/env/`, `terraform/posthog/backend/` | Per-environment config subdirectories attached to a Terraform root | Hold `.hcl` backend configs and `.tfvars` variable files. Not Terraform roots in their own right — no `.tf` files, you don't run `terraform init` against them. Passed to a root's `terraform init -backend-config=…` / `-var-file=…`. |

The two Terraform roots share the same per-environment GCS state bucket
(`catvox-tf-state-<gcp-project-id>`); only the prefix differs. Active Dev
points at `kathelix-catvox-dev`; future Prod will use a separate state/config
set for the preserved `kathelix-catvox-prod` project. See ADR-0017, ADR-0018,
ADR-0020, and `docs/CREATE_NEW_ENVIRONMENT.md`.

## GCP root (`terraform/`)

Named environments use explicit files keyed by environment name:

- `terraform/backend/<environment>.hcl` for remote-state backend config
- `terraform/env/<environment>.tfvars` for environment-specific input values

Terraform backend blocks cannot use normal input variables, so backend config
must be passed explicitly during `terraform init` for each environment.
The Makefile rejects backend/tfvars basenames that do not match
`CATVOX_ENVIRONMENT`.

Example local flow:

```bash
cp backend/dev.hcl.example backend/dev.hcl
cp env/dev.tfvars.example env/dev.tfvars
make terraform-plan CATVOX_ENVIRONMENT=dev
```

Do not put secrets in committed tfvars files. Commit only `.example` files when
documenting required values.

## PostHog root (`terraform/posthog/`)

The PostHog root uses the same backend HCL convention but intentionally does
not have an `env/<environment>.tfvars` directory. Per-environment values come
from `config/environments/<environment>.xcconfig` (read by the Makefile) and
the matching per-environment GitHub Environment (read by CI). See
`terraform/posthog/README.md` and ADR-0020.
The Makefile rejects backend/tfvars basenames that do not match
`CATVOX_ENVIRONMENT`.
