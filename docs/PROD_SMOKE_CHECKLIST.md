# Production Smoke Checklist

This runbook defines the protected, non-invasive Prod smoke path for CatVox.
It is intentionally separate from Dev integration testing: Prod smoke checks
must not write Firestore documents, create GCS objects, invoke mutating Cloud
Function paths, start Cloud Build, or register App Check debug tokens.

## When To Run

Run this checklist after a protected Prod deploy or before launch cutover when
the goal is to confirm that the deployed slice is healthy and configured as
expected.

Do not run `make functions-integration` against Prod. Prod must not be present
in `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`.

## Automated Smoke

From the repository root:

```bash
make prod-smoke
```

After Step 3 of issue #38 lands real Prod Firebase, Functions, and Terraform
state values, operators may make skips fail loudly:

```bash
CATVOX_PROD_SMOKE_REQUIRE_LIVE=1 make prod-smoke
```

The command forces `CATVOX_ENVIRONMENT=prod` and performs only read-only checks:

| Check | Mutation risk | Expected result |
|---|---:|---|
| Parse and validate `config/environments/prod.xcconfig` | none | Prod identity values match `kathelix-catvox-prod` and `com.kathelix.catvox`; no Dev references; no `prod` mutable-test allowlist |
| Validate committed Prod Firebase plist when present | none | `GoogleService-Info-prod.plist` matches Prod project, app ID, API key, and bundle ID |
| Terraform `plan -refresh-only` when live config and local secrets are available | read-only cloud refresh | Plan completes without applying changes |
| Firestore database describe when live config is available | read-only control-plane request | `(default)` database is readable in `kathelix-catvox-prod` |
| HTTPS GET to each backend endpoint when live hosts are configured | non-mutating request | Endpoint returns `401 app_check_unauthorized` before business logic runs |

Pre-provisioning behavior is explicit. While Step 3 placeholders remain in
`config/environments/prod.xcconfig` or `GoogleService-Info-prod.plist` is absent,
the command prints skipped live checks instead of pretending that live Prod was
smoked.

## Manual Operator Checks

Before treating a Prod deploy as healthy, verify these items manually:

- GitHub Environment `prod` exists and is protected with required reviewer
  approval before deployment or apply steps can use its secrets.
- `prod` secrets do not include `TF_VAR_APP_CHECK_DEBUG_TOKEN`.
- Firebase App Check for the Prod iOS app uses App Attest only. No Debug
  Provider token is registered for the Prod app.
- `config/environments/prod.xcconfig` has no Step 3 placeholders after real
  Prod provisioning:
  `CATVOX_FIREBASE_APP_ID`, `CATVOX_FIREBASE_API_KEY`,
  `CATVOX_SIGNED_UPLOAD_URL_HOST`, and `CATVOX_ANALYSE_VIDEO_HOST`.
- `CatVox/Resources/Firebase/GoogleService-Info-prod.plist` exists, is
  committed if that remains the chosen repo contract, and passes the automated
  plist check.
- A Release/App Store archive selects `prod`, fails loudly if the Prod plist is
  missing, and does not reference Dev project IDs, Dev bundle IDs, Debug App
  Check providers, or debug-token environment variables.
- Terraform plan output for Prod is reviewed by a human before any apply. A
  Prod smoke run must never be used as approval to apply infrastructure.
- Cloud Run / Cloud Functions endpoints match the committed Prod hosts and the
  smoke GET checks return App Check rejection rather than signed upload URLs,
  quota reservations, or analysis responses.
- Firestore and GCS are inspected only through read/list/describe operations.
  Do not create test documents or upload objects in Prod.

## Failure Handling

If `make prod-smoke` fails after live Prod values have landed:

1. Stop the release or cutover.
2. Keep the failed command output with the PR or release notes.
3. Fix configuration through a reviewed PR or revert the deploy path.
4. Re-run the smoke command after the fix. Do not substitute Dev integration
   tests for Prod smoke.

If a check is skipped after Step 3 should be complete, re-run with
`CATVOX_PROD_SMOKE_REQUIRE_LIVE=1` to turn skips into failures and fix the
missing precondition.
