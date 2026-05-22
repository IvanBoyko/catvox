# Terraform Environment Conventions

CatVox has two Terraform roots, each with its own state, lifecycle, and CI
workflow:

- `terraform/` — GCP/Firebase foundation (see `terraform/README.md` you are
  reading; state prefix `catvox/state`, workflow `.github/workflows/terraform.yml`).
- `terraform/posthog/` — PostHog analytics (state prefix `posthog/state`,
  workflow `.github/workflows/posthog-terraform.yml`; see
  `terraform/posthog/README.md` and ADR-0020).

Both roots share the same per-environment GCS state bucket
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

Example local flow:

```bash
cp backend/dev.hcl.example backend/dev.hcl
cp env/dev.tfvars.example env/dev.tfvars
make terraform-plan CATVOX_TERRAFORM_ENV=dev
```

Do not put secrets in committed tfvars files. Commit only `.example` files when
documenting required values.

## PostHog root (`terraform/posthog/`)

The PostHog root uses the same backend HCL convention but intentionally does
not have an `env/<environment>.tfvars` directory. Per-environment values come
from `config/environments/<environment>.xcconfig` (read by the Makefile) and
the matching per-environment GitHub Environment (read by CI). See
`terraform/posthog/README.md` and ADR-0020.
