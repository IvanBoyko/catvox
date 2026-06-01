# CI Bootstrap

This document covers one-time repository and GitHub Actions setup that is not
owned by a single CatVox environment. Per-environment creation is documented in
`docs/CREATE_NEW_ENVIRONMENT.md`.

## GitHub Actions Availability

GitHub Actions must be enabled for `kathelix/catvox`. The repository uses four
workflow families:

- iOS build and tests on PRs and pushes.
- GCP Terraform plan on PRs and automatic apply on merge to `main` for the mutable
  environment, plus a manual `workflow_dispatch` apply for protected environments.
- PostHog Terraform plan on PRs, automatic mutable-environment apply on merge to
  `main`, and manual protected-environment apply through `workflow_dispatch` from
  `main` (separate root, separate state prefix; see ADR-0020).
- Firebase Functions build on PRs and, on merge to `main`, an ordered pipeline:
  deploy + integration on the mutable environment, then an approval-gated
  `deploy-prod` job for protected environments.

The Terraform and Functions deploy paths authenticate to Google Cloud through
Workload Identity Federation (WIF). Do not create or store long-lived service
account keys.

## GitHub Environments

Use GitHub Environments to scope cloud secrets by target environment:

| Tier | Protection |
|---|---|
| Mutable | Unprotected or lightly protected. PR/main deploy paths target it automatically. |
| Protected | Required reviewers. Require explicit approval before any production deploy. |

Both workflows model promotion as **mutable automatic, protected manual**, by
different mechanisms until the delivery orchestrator (#106) unifies them.
Terraform: a separate `apply-prod` job triggered by `workflow_dispatch` from
`main`. Functions: `deploy-prod` runs in the push pipeline after the
mutable-environment deploy + integration (`needs: integration-after-deploy`) and
is held at the protected environment's approval gate — approving it is the manual
promote. Neither has an environment chooser.
PostHog Terraform follows the same topology as the GCP Terraform workflow: the
mutable environment applies automatically on merge to `main`, while protected
environments apply only through the manual dispatch path.
Each shared apply/deploy body lives in a reusable workflow (`terraform-apply.yml`,
`functions-deploy.yml`) invoked with the target environment, and GCP
authentication is the `gcp-auth` composite action. A protected GitHub
Environment's protection (required reviewers) gates its run, and its WIF trust
additionally requires `ref=refs/heads/main` (ADR-0024).
For a protected environment, do not set the App Check debug-token secret, keep
mutable integration-test allowlists out of it (no post-deploy integration tests
run against it — use `make smoke CATVOX_ENVIRONMENT=<env>`), and keep the
Firebase iOS app deletion policy set to `ABANDON` in its
`config/environments/<env>.xcconfig`. The first apply for a brand-new protected
environment is operator-local (it creates the WIF pool and `catvox-ci-sa`); every
subsequent apply and deploy goes through this protected dispatch path.

Required secrets per environment:

| Secret | Purpose |
|---|---|
| `TF_VAR_ALERT_EMAIL` | Terraform alert recipient. |
| `TF_VAR_APP_CHECK_DEBUG_TOKEN` | Mutable / integration-safe environments only. |
| `POSTHOG_API_KEY` | PostHog scoped personal API key for this environment's PostHog project. `make posthog-environment-provision` stores it after configuring/verifying the GitHub Environment. |

Non-secret environment values are committed in
`config/environments/<env>.xcconfig`. This includes `CATVOX_PROJECT_ID`,
`CATVOX_GCP_WIF_PROVIDER`, and `CATVOX_GCP_CI_SERVICE_ACCOUNT`; workflows read
those values before WIF authentication. See ADR-0021 and ADR-0022.

## WIF Trust Model

Each GCP project gets its own `catvox-ci-sa`, WIF pool, and OIDC provider. The
provider trusts only GitHub Actions tokens from `kathelix/catvox` running in the
GitHub Environment matching `CATVOX_ENVIRONMENT`, and — when the environment pins
one — a specific ref. The attribute condition combines these claims:

```text
assertion.repository == "kathelix/catvox" && assertion.environment == "<env>"
```

The optional per-environment ref pin is set via `CATVOX_GCP_WIF_GITHUB_REF`, and
the `catvox-ci-sa` binding is scoped to `attribute.environment/<env>`. See
ADR-0024.

Terraform manages the per-project WIF pool/provider and the
`roles/iam.workloadIdentityUser` binding. Environment creation still has to
bootstrap the remote Terraform state bucket before the first Terraform init,
because Terraform cannot manage the bucket that stores its own state.

`catvox-ci-sa` is intentionally not granted `workloadIdentityPoolAdmin`, so it
can refresh but not update these resources. Apply any change to the WIF pool,
provider, or `ci_sa_wif_binding` operator-local before merging it: a WIF change
routed through the post-merge CI apply destroys the binding (the `member` change
forces replacement) and then fails the provider update, breaking CI
authentication for the whole environment until an operator-local
`make terraform-apply CATVOX_ENVIRONMENT=<env> CONFIRM=apply` reconciles it.

## One-Time Repository Checklist

1. Confirm GitHub Actions is enabled for the repository.
2. Create the mutable environment's GitHub Environment (named to match the
   environment).
3. For a protected environment, create a separate protected GitHub Environment
   (named to match the environment) with required reviewers.
4. Keep repository-level cloud secrets empty or legacy-only; active cloud deploy
   secrets should live on GitHub Environments.
5. Do not store GCP service account keys in GitHub, locally, or in Terraform
   variables.
