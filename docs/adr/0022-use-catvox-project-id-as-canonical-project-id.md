# ADR-0022: Use CATVOX_PROJECT_ID as Canonical Project ID

- Status: Accepted
- Date: 2026-05-24
- Owners: Kathelix / CatVox
- Supersedes: ADR-0021 project-ID key naming details
- Related docs: `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/CI_BOOTSTRAP.md`, `project.yml`, `Makefile`

## Context

ADR-0021 moved non-secret environment values into committed
`config/environments/<env>.xcconfig`, but it kept multiple committed names for
the same GCP/Firebase project identifier: `GCP_PROJECT_ID`,
`FIREBASE_PROJECT`, and `CATVOX_PROJECT_ID`. The environment files also kept
both `CATVOX_PRODUCT_BUNDLE_IDENTIFIER` and `CATVOX_IOS_BUNDLE_ID` for the same
iOS bundle identifier.

Those aliases made the environment definition harder to review because multiple
keys had to stay identical even though they represented one CatVox environment
property.

## Decision

`CATVOX_PROJECT_ID` is the canonical committed project-ID key for CatVox
environments. `GCP_PROJECT_ID` and `FIREBASE_PROJECT` are retired and must not
be reintroduced in `config/environments/<env>.xcconfig`, Makefile interfaces,
CI actions, or active runbooks.

`CATVOX_IOS_BUNDLE_ID` is the canonical committed iOS bundle-ID key.
`CATVOX_PRODUCT_BUNDLE_IDENTIFIER` is retired; XcodeGen maps
`CATVOX_IOS_BUNDLE_ID` to Xcode's `PRODUCT_BUNDLE_IDENTIFIER` setting.

The obsolete Terraform-managed Secret Manager secret named `GCP_PROJECT_ID` is
removed. Project identity is non-secret environment configuration, not a runtime
secret. Deployed Cloud Functions may still use Firebase-provided runtime
metadata as a platform fallback when `CATVOX_PROJECT_ID` is unavailable at
runtime.

## Consequences

- Each environment file has one project-ID value and one iOS bundle-ID value.
- Makefile, CI, Terraform, and deployment commands use the CatVox-prefixed key
  consistently.
- Terraform plans include deletion of the retired `GCP_PROJECT_ID` Secret
  Manager resource from environments where it still exists.
- Historical ADRs and archive reports may still mention retired names when
  describing the previous state.
