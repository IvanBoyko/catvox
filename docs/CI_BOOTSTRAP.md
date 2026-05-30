# CI Bootstrap

This document covers one-time repository and GitHub Actions setup that is not
owned by a single CatVox environment. Per-environment creation is documented in
`docs/CREATE_NEW_ENVIRONMENT.md`.

## GitHub Actions Availability

GitHub Actions must be enabled for `kathelix/catvox`. The repository uses four
workflow families:

- iOS build and tests on PRs and pushes.
- GCP Terraform plan on PRs and automatic apply on merge to `main` (Dev), plus a
  manual `workflow_dispatch` apply for protected environments (e.g. prod).
- PostHog Terraform plan on PRs and apply on merge to `main` (separate root,
  separate state prefix; see ADR-0020).
- Firebase Functions build on PRs and automatic deploy plus integration after
  merge to `main` (Dev), plus a manual `workflow_dispatch` deploy for protected
  environments (e.g. prod).

The Terraform and Functions deploy paths authenticate to Google Cloud through
Workload Identity Federation (WIF). Do not create or store long-lived service
account keys.

## GitHub Environments

Use GitHub Environments to scope cloud secrets by target environment:

| Environment | Protection |
|---|---|
| `dev` | Unprotected or lightly protected. PR/main deploy paths target Dev. |
| `prod` | Protected. Require explicit approval before any production deploy. |

Both the Terraform and Functions workflows expose a protected delivery path for
environments that have no automatic per-push deploy. A manual `workflow_dispatch`
with an `environment` input (default `prod`) runs an `apply-dispatch` /
`deploy-dispatch` job whose `environment:` is the chosen environment, gated to
`main`; the automatic per-push apply/deploy stays scoped to `dev`. The chosen
GitHub Environment's protection (required reviewers) gates the run, and the
environment's WIF trust additionally requires `ref=refs/heads/main` (ADR-0024).
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
| `POSTHOG_API_KEY` | PostHog scoped personal API key for this environment's PostHog project. |

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

## One-Time Repository Checklist

1. Confirm GitHub Actions is enabled for the repository.
2. Create the `dev` GitHub Environment.
3. For a protected environment, create a separate protected GitHub Environment
   (named to match the environment) with required reviewers.
4. Keep repository-level cloud secrets empty or legacy-only; active cloud deploy
   secrets should live on GitHub Environments.
5. Do not store GCP service account keys in GitHub, locally, or in Terraform
   variables.
