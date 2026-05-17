# ADR-0018: Create Dedicated Dev Environment

- Status: Accepted
- Date: 2026-05-16
- Owners: Kathelix / CatVox
- Related docs: `docs/HLD.md`, `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/CI_BOOTSTRAP.md`, `docs/adr/0017-environment-configuration-model.md`

## Context

CatVox originally used one GCP/Firebase project, `kathelix-catvox-prod`, while
operationally treating it as Dev. ADR-0017 defined the named-environment model,
but the live project name remained misleading and carried Dev App Check,
Functions, Terraform state, and CI secrets.

Deleting `kathelix-catvox-prod` is risky because GCP project IDs can be hard to
reclaim immediately after deletion. The project ID should remain available for
the future real production environment.

## Decision

Create a real Dev environment in a separate GCP/Firebase project:

- Environment name: `dev`
- GCP/Firebase project ID: `kathelix-catvox-dev`
- Dev iOS bundle ID: `com.kathelix.catvox.dev`
- Dev Terraform state bucket: `catvox-tf-state-kathelix-catvox-dev`
- Dev Firebase plist: `CatVox/Resources/Firebase/GoogleService-Info-dev.plist`
- GitHub Environment: `dev`

Keep `kathelix-catvox-prod` alive as a preserved project container for the
future real Prod slice. After the new Dev environment passes deploy,
integration, and device-scan validation, clean Dev leftovers from the old
project without deleting the project itself. That cleanup was completed on
2026-05-16; see `docs/LEGACY_PRESPLIT_CLEANUP_REPORT_2026-05-16.md`.

Terraform environment input values stay in `terraform/env/<env>.tfvars` because
Terraform needs infra-only and sensitive values that do not belong in app
xcconfig files. App/runtime values stay in `config/environments/<env>.xcconfig`.

## Consequences

### Positive

- Dev now has a project ID that matches its operational role.
- Future Prod can use `kathelix-catvox-prod` without Dev data, debug tokens, or
  CI state after the completed cleanup pass.
- Firebase plist selection can be validated against the selected environment,
  project ID, app ID, API key, and bundle ID before app builds.
- GitHub Actions secrets are scoped to the `dev` Environment instead of being
  treated as repository-global deploy settings.

### Negative / Trade-offs

- Dev cutover requires coordinated updates across GCP, Firebase, Terraform,
  GitHub Environments, Xcode build settings, and local ignored tfvars files.
- Future Prod provisioning must intentionally import/reuse or recreate the
  preserved Firebase iOS app and Firestore database container.
- PostHog project isolation is deferred to issue #37. The current PostHog
  project is treated as Dev for this slice and was renamed outside Terraform;
  future work must split or explicitly route analytics per environment.
- Until the future Prod slice, Release builds still use the active Dev config;
  App Store readiness remains out of scope for this decision.
