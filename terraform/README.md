# Terraform Environment Conventions

CatVox currently has one Terraform root. Until the real environment split is
provisioned, it still points at the live-as-Dev project described in ADR-0013.

Future named environments should use explicit files keyed by environment name:

- `terraform/backend/<environment>.hcl` for remote-state backend config
- `terraform/env/<environment>.tfvars` for environment-specific input values

Terraform backend blocks cannot use normal input variables, so backend config
must be passed explicitly during `terraform init` for each environment.

Example future flow:

```bash
terraform init -backend-config=backend/dev.hcl
terraform plan -var-file=env/dev.tfvars
```

Do not put secrets in committed tfvars files. Commit only `.example` files when
documenting required values.
