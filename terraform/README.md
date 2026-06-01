# Terraform Environment Conventions

CatVox's Terraform layout places each Terraform root in its own subdirectory
under `terraform/` (a pure container):

| Path | Kind | Purpose |
|---|---|---|
| `terraform/core/` | Terraform root (GCP/Firebase foundation) | `.tf` files for GCP/Firebase infrastructure. State prefix `catvox/state`. CI workflow `.github/workflows/terraform.yml`. |
| `terraform/posthog/` | Terraform root (PostHog analytics) | `.tf` files for PostHog projects/dashboards/insights. State prefix `posthog/state`. CI workflow `.github/workflows/posthog-terraform.yml`. See `terraform/posthog/README.md` and ADR-0020. |

The two Terraform roots share the same per-environment GCS state bucket
(`catvox-tf-state-<gcp-project-id>`); only the prefix differs. Per-environment
state/config conventions are specified in the Environment Model section of
`docs/TRD.md`. See ADR-0017, ADR-0018, ADR-0020, and
`docs/CREATE_NEW_ENVIRONMENT.md`.

## Provider Lock Files

Both Terraform roots commit their provider lock files:

- `terraform/core/.terraform.lock.hcl`
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

## GCP/Firebase root (`terraform/core/`)

Named environments use explicit files keyed by environment name:

- `terraform/core/env/<environment>.tfvars` for environment-specific private values

Non-secret foundation values live in
`config/environments/<environment>.xcconfig` and are passed by the Makefile as
`TF_VAR_*` values or inline `-backend-config` arguments during `terraform init`;
the ignored tfvars file holds only `app_check_debug_token` and `alert_email`. The
Makefile rejects tfvars basenames that do not match `CATVOX_ENVIRONMENT`. The
parameterization model is specified in the Environment Model section of
`docs/TRD.md`. See ADR-0021.

Example local flow:

```bash
cp terraform/core/env/<env>.tfvars.example terraform/core/env/<env>.tfvars
# Fill in private values
make terraform-plan CATVOX_ENVIRONMENT=<env>
```

Do not put secrets in committed tfvars files. Commit only `.example` files when
documenting required private values. See ADR-0021.

## PostHog root (`terraform/posthog/`)

The PostHog root intentionally does
not have an `env/<environment>.tfvars` directory. Per-environment values come
from `config/environments/<environment>.xcconfig` (read by the Makefile) and
the matching per-environment GitHub Environment (read by CI). See
`terraform/posthog/README.md`, ADR-0020, and the Environment Model section of
`docs/TRD.md`.
