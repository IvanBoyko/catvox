# CI Bootstrap

This document covers one-time repository and GitHub Actions setup that is not
owned by a single CatVox environment. Per-environment creation is documented in
`docs/CREATE_NEW_ENVIRONMENT.md`.

## GitHub Actions Availability

GitHub Actions must be enabled for `kathelix/catvox`. The repository uses three
workflow families:

- iOS build and tests on PRs and pushes.
- Terraform plan on PRs and apply on merge to `main`.
- Firebase Functions build on PRs and deploy plus integration after merge to
  `main`.

The Terraform and Functions deploy paths authenticate to Google Cloud through
Workload Identity Federation (WIF). Do not create or store long-lived service
account keys.

## GitHub Environments

Use GitHub Environments to scope cloud secrets by target environment:

| Environment | Protection |
|---|---|
| `dev` | Unprotected or lightly protected. PR/main deploy paths target Dev. |
| `prod` | Protected. Require explicit approval before any production deploy. |

The current workflows target the `dev` GitHub Environment. A future Prod slice
must add separate protected workflow jobs instead of reusing the Dev deploy path.

Required secrets per environment:

| Secret | Purpose |
|---|---|
| `GCP_PROJECT_ID` | Target GCP/Firebase project ID. |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | WIF provider resource name for that project. |
| `GCP_SERVICE_ACCOUNT` | CI service account email for that project. |
| `TF_VAR_ALERT_EMAIL` | Terraform alert recipient. |
| `TF_VAR_APP_CHECK_DEBUG_TOKEN` | Dev/integration-safe environments only. |

## WIF Trust Model

Each GCP project gets its own `catvox-ci-sa`, WIF pool, and OIDC provider. The
provider trusts only GitHub Actions tokens from `kathelix/catvox` through the
repository attribute condition:

```text
assertion.repository == "kathelix/catvox"
```

Terraform manages the per-project WIF pool/provider and the
`roles/iam.workloadIdentityUser` binding. Environment creation still has to
bootstrap the remote Terraform state bucket before the first Terraform init,
because Terraform cannot manage the bucket that stores its own state.

## One-Time Repository Checklist

1. Confirm GitHub Actions is enabled for the repository.
2. Create the `dev` GitHub Environment.
3. For future Prod, create a separate protected `prod` GitHub Environment with
   required reviewers.
4. Keep repository-level cloud secrets empty or legacy-only; active cloud deploy
   secrets should live on GitHub Environments.
5. Do not store GCP service account keys in GitHub, locally, or in Terraform
   variables.
