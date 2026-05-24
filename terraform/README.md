# Terraform Environment Conventions

CatVox's Terraform layout has three kinds of directories under `terraform/`:

| Path | Kind | Purpose |
|---|---|---|
| `terraform/` | Terraform root (GCP/Firebase foundation) | `.tf` files for GCP/Firebase infrastructure. State prefix `catvox/state`. CI workflow `.github/workflows/terraform.yml`. |
| `terraform/posthog/` | Terraform root (PostHog analytics) | `.tf` files for PostHog projects/dashboards/insights. State prefix `posthog/state`. CI workflow `.github/workflows/posthog-terraform.yml`. See `terraform/posthog/README.md` and ADR-0020. |
| `terraform/env/` | Per-environment private inputs | Holds secrets-only `.tfvars` files. Not a Terraform root in its own right — no `.tf` files. Passed to a root's `terraform plan/apply -var-file=…`. |

The two Terraform roots share the same per-environment GCS state bucket
(`catvox-tf-state-<gcp-project-id>`); only the prefix differs. Active Dev
points at `kathelix-catvox-dev`; future Prod will use a separate state/config
set for the preserved `kathelix-catvox-prod` project. See ADR-0017, ADR-0018,
ADR-0020, and `docs/CREATE_NEW_ENVIRONMENT.md`.

## Provider Lock Files

Both Terraform roots commit their provider lock files:

- `terraform/.terraform.lock.hcl`
- `terraform/posthog/.terraform.lock.hcl`

When provider constraints change, regenerate the affected root's lock file with
the platforms used by local development and CI:

```bash
terraform -chdir=<root> providers lock \
  -platform=linux_amd64 \
  -platform=darwin_amd64 \
  -platform=darwin_arm64
```

Do not use `terraform init -upgrade` unless the provider upgrade is intentional.

## GCP root (`terraform/`)

Named environments use explicit files keyed by environment name:

- `terraform/env/<environment>.tfvars` for environment-specific private values

Non-secret GCP/Firebase foundation values live in
`config/environments/<environment>.xcconfig` and are passed by the Makefile as
`TF_VAR_*` values or inline `-backend-config` arguments during `terraform init`. The ignored tfvars file remains only for
`app_check_debug_token` and `alert_email`. The Makefile rejects tfvars
basenames that do not match `CATVOX_ENVIRONMENT`.

Example local flow:

```bash
cp env/dev.tfvars.example env/dev.tfvars
# Fill in private values
make terraform-plan CATVOX_ENVIRONMENT=dev
```

Do not put secrets in committed tfvars files. Commit only `.example` files when
documenting required private values. See ADR-0021.

## PostHog root (`terraform/posthog/`)

The PostHog root intentionally does
not have an `env/<environment>.tfvars` directory. Per-environment values come
from `config/environments/<environment>.xcconfig` (read by the Makefile) and
the matching per-environment GitHub Environment (read by CI). See
`terraform/posthog/README.md` and ADR-0020.
