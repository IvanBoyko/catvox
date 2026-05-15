# ADR-0017: Environment Configuration Model

- Status: Accepted
- Date: 2026-05-15
- Owners: Kathelix / CatVox
- Related docs: `docs/HLD.md`, `docs/TRD.md`, `docs/TODO.md`, `project.yml`, `Makefile`, `.github/workflows/`

## Context

CatVox currently has one deployed GCP/Firebase project named
`kathelix-catvox-prod`, but ADR-0013 treats it operationally as Dev until a real
production environment is split out.

The codebase also contains project-specific values in several layers: iOS
backend URLs, Firebase plist metadata, PostHog configuration, Cloud Functions
runtime service account emails, integration-test defaults, Makefile variables,
GitHub Actions secrets, and Terraform backend state. Creating a second
environment before parameterizing those values would make the split large and
fragile.

Although the first real split is Dev and Prod, future needs may introduce more
named environments such as staging, demo, or experiment. The implementation
should therefore treat an environment name as configuration data instead of
hard-coding only two cases.

## Decision

CatVox will use a generic named-environment configuration model.

Initial environment names are:

- `dev` for internal development and integration testing
- `prod` for App Store production

Environment-specific values must be supplied through build settings, scripts,
CI secrets, Terraform backend/tfvars files, or deployment environment variables
rather than scattered source constants.

Each environment owns its own:

- GCP/Firebase project
- Firebase iOS app and `GoogleService-Info` plist
- Firebase App Check configuration and debug tokens
- Cloud Functions deployment and backend endpoints
- GCS buckets, Firestore data, Secret Manager secrets, and Artifact Registry
- PostHog project/token or otherwise isolated analytics routing
- GitHub secret/variable set
- Terraform state

iOS bundle IDs are environment-specific where needed. The initial convention is:

- `com.kathelix.catvox.dev` for Dev/internal builds
- `com.kathelix.catvox` for App Store Prod

Mutable backend integration tests may run only against environments explicitly
marked integration-safe. Prod receives only protected, non-invasive smoke tests.

## Consequences

### Positive

- The first Dev/Prod split can be implemented in smaller, reviewable steps.
- Future environments can be added by supplying a new environment name and
  config set instead of changing source branches throughout the app/backend.
- Integration testing remains safely isolated from production user data.
- App Store builds have a clearer path to Release-only Firebase, App Check,
  backend, and analytics configuration.

### Negative / Trade-offs

- More configuration values must be managed consistently across local
  development, CI, Firebase, GCP, XcodeGen, and App Store Connect.
- The build and deploy tooling needs stricter validation so missing environment
  values fail early.
- The current `kathelix-catvox-prod` name remains confusing until the real split
  and cutover are complete.

## Implementation Notes

- Pre-split work should preserve current behavior while moving values behind
  named configuration keys.
- Terraform backend configuration cannot use normal Terraform variables, so
  future state files should use explicit backend config files such as
  `terraform/backend/<environment>.hcl`.
- Future variable files should follow a matching convention such as
  `terraform/env/<environment>.tfvars`.
- Runtime Cloud Functions use the same service-account name within each
  environment project. Distinct projects therefore produce distinct IAM
  principals, for example
  `catvox-backend-sa@<project-id>.iam.gserviceaccount.com`.
- Product code should use generic keys such as `CATVOX_ENVIRONMENT` rather than
  `CATVOX_DEV` or `CATVOX_PROD`.

## Future Work

- Firebase plist selection should follow a convention such as
  `GoogleService-Info-<Environment>.plist`, copied or selected by build
  configuration before app build.
