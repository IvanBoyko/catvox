# Terraform Environment Conventions

CatVox currently has one Terraform root. Active Dev points at
`kathelix-catvox-dev`; future Prod will use a separate state/config set for the
preserved `kathelix-catvox-prod` project. See ADR-0017, ADR-0018, and
`docs/CREATE_NEW_ENVIRONMENT.md`.

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
