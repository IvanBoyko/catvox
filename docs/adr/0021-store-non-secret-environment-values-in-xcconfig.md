# ADR-0021: Store Non-Secret Environment Values in xcconfig

- Status: Accepted
- Date: 2026-05-22
- Owners: Kathelix / CatVox
- Supersedes: the ADR-0018 implementation note that Terraform environment input values stay broadly in `terraform/env/<env>.tfvars`
- Amended: 2026-05-23: `enable_app_check_debug_token` and `app_check_debug_token_display_name` have been removed in favor of token presence driving registration (PR #60).
- Related docs: `docs/HLD.md`, `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/CI_BOOTSTRAP.md`, `docs/adr/0018-create-dedicated-dev-environment.md`, `docs/adr/0020-bind-posthog-projects-to-catvox-environments.md`, GitHub issue #38

## Context

ADR-0017 introduced named environments and ADR-0018 created the dedicated Dev
environment. The first implementation split environment values across three
places:

- committed `config/environments/<env>.xcconfig`
- GitHub Environment secrets
- ignored `terraform/env/<env>.tfvars`

That was useful during the initial split, but it left non-secret identity values
in secret stores and ignored local files. PR #56 established a better precedent
for PostHog Terraform: `POSTHOG_API_KEY` stays in the GitHub Environment, while
non-secret provider identifiers live in `config/environments/<env>.xcconfig`
and flow through the Makefile as Terraform variables.

The same rule should apply to the GCP/Firebase foundation values. GCP project
IDs, WIF provider resource names, CI service account emails, Firebase app
display names, bundle IDs, regions, Firestore locations, App Check debug-token
display names, and boolean environment toggles are operational configuration,
not credentials. Keeping them in committed environment config makes drift easier
to review and keeps future Prod provisioning from depending on hidden local
state.

## Decision

For CatVox environment configuration, non-secret per-environment values live in
`config/environments/<env>.xcconfig`.

GitHub Environment secrets and ignored `terraform/env/<env>.tfvars` files hold
only true secrets or deliberately private values.

For the current Dev environment this means:

- `GCP_PROJECT_ID` remains in xcconfig and is no longer required as a GitHub
  Environment secret.
- `CATVOX_GCP_CI_SERVICE_ACCOUNT` stores the full CI service account email.
- `CATVOX_GCP_WIF_PROVIDER` stores the full WIF provider resource name.
- GCP Terraform non-secret inputs move to xcconfig, including region, Firestore
  location, state bucket, Firebase iOS display name, Firebase iOS app deletion
  policy, Apple team ID, App Check debug-token enablement, App Check debug-token
  display name, and Cloud Functions source-bucket IAM management.
- `terraform/env/<env>.tfvars` remains, but only for `app_check_debug_token` and
  `alert_email`.

The CatVox values treated as secrets or intentionally private are:

- `POSTHOG_API_KEY`: scoped PostHog API credential.
- `TF_VAR_APP_CHECK_DEBUG_TOKEN` / `app_check_debug_token`: Firebase App Check
  debug token used by Dev and mutable integration tests.
- `TF_VAR_ALERT_EMAIL` / `alert_email`: operator email address. It is not a
  machine credential, but it is operator PII and stays outside committed files.

Everything else needed to identify an environment should default to committed
xcconfig unless a future ADR explicitly classifies it as secret or private.

Workflows that authenticate to GCP read the selected xcconfig before WIF auth,
write the required values to both `$GITHUB_OUTPUT` and `$GITHUB_ENV`, and pass
the WIF provider and service account to `google-github-actions/auth` from step
outputs. The same values then flow to Makefile-based steps through environment
variables.

Terraform variables that receive xcconfig-driven values must fail loudly when
required values are missing or malformed. Error messages should name the
xcconfig key that must be fixed.

Makefile-driven GCP Terraform commands must also reject ignored tfvars files
that still contain migrated non-secret keys, because Terraform `-var-file`
values override `TF_VAR_*` environment values.

Boolean values committed to xcconfig use canonical lowercase `true` or `false`
only. Shell tooling may trim whitespace and normalize case before passing those
values on, but it must not accept alternate forms such as `1`, `0`, `yes`, or
`no` as environment-file values.

## Consequences

### Positive

- The committed environment config becomes the reviewable source of truth for
  app, backend, analytics, CI auth identity, and Terraform non-secret inputs.
- GitHub Environment secrets shrink to values that actually need secret storage.
- Future Prod setup has fewer hidden prerequisites and less copy/paste drift.
- Local and CI Makefile runs use the same environment value source.
- The remaining ignored tfvars file has a narrow, understandable purpose:
  local secret fallback for App Check debug tokens and alert email.

### Negative / Trade-offs

- More committed xcconfig keys are infrastructure-facing and not directly
  consumed by the iOS app.
- GCP WIF provider and CI service account values must be updated in xcconfig if
  those resources are recreated.
- Workflows need an explicit xcconfig-read step before authentication, because
  GitHub Actions cannot use runtime step output in a top-level `env:` block.

## Alternatives Considered

### Keep GCP CI identity in GitHub Environment secrets

Rejected because project IDs, WIF provider paths, and service account emails
are not credentials. Keeping them as secrets hides reviewable drift and repeats
the pre-PR #56 PostHog problem.

### Compose service account and WIF provider values from pieces

Rejected in favor of storing full strings. Full strings are mechanical,
copy/paste-verifiable, and avoid encoding provider path knowledge across
Makefile, workflow, and documentation layers.

### Retire `terraform/env/<env>.tfvars` entirely

Rejected for now because Dev still needs a local ignored place for the App Check
debug token fallback and the alert email. Retiring tfvars can be reconsidered if
those two values move to a different local secret mechanism.
