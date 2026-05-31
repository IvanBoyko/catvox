# Environment Smoke Checklist

This runbook defines the non-invasive smoke path for a CatVox environment. It is
environment-agnostic: run it against any environment with
`CATVOX_ENVIRONMENT=<env>`. It matters most for protected environments before and
after a deploy, but can also be run against a mutable environment to exercise the
smoke itself.

Smoke checks must not write Firestore documents, create GCS objects, invoke
mutating Cloud Function paths, start Cloud Build, or register App Check debug
tokens. It is intentionally separate from `make functions-integration`, which is
mutating and runs only against integration-safe environments.

## When To Run

Run this checklist after a deploy, or before a launch/cutover, to confirm the
deployed environment is healthy and configured as expected.

Do not run `make functions-integration` against a protected environment — a
protected environment must not appear in `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`.

## Automated Smoke

From the repository root:

```bash
CATVOX_ENVIRONMENT=<env> make smoke
```

Once the environment's Firebase, Functions, and Terraform state values are live,
make skipped live checks fail loudly instead:

```bash
CATVOX_SMOKE_REQUIRE_LIVE=1 CATVOX_ENVIRONMENT=<env> make smoke
```

`make smoke` reads `config/environments/<env>.xcconfig` and performs only
read-only checks:

| Check | Mutation risk | Expected result |
|---|---:|---|
| Parse and validate `config/environments/<env>.xcconfig` | none | Identity values are internally consistent, reference no other environment, and a protected environment is absent from the mutable-test allowlist |
| Validate the committed Firebase plist when present | none | `GoogleService-Info-<env>.plist` matches the environment's project, app ID, API key, and bundle ID |
| Terraform `plan -refresh-only` when live config and local secrets are available | read-only cloud refresh | Plan completes without applying changes |
| Firestore database describe when live config is available | read-only control-plane request | `(default)` database is readable |
| HTTPS GET to each backend endpoint when live hosts are configured | non-mutating request | Endpoint returns `401 app_check_unauthorized` before business logic runs |

Pre-provisioning behavior is explicit. While placeholders remain in
`config/environments/<env>.xcconfig` or the plist is absent, the command prints
skipped live checks instead of pretending the live environment was smoked.

## Manual Operator Checks

Before treating a protected-environment deploy as healthy, verify these items
manually:

- The environment's GitHub Environment exists and is protected with required
  reviewer approval before deployment or apply steps can use its secrets.
- The environment's secrets do not include `TF_VAR_APP_CHECK_DEBUG_TOKEN`.
- Firebase App Check for the environment's iOS app uses App Attest only. No Debug
  Provider token is registered.
- `config/environments/<env>.xcconfig` has no leftover `replace-with-*`
  placeholders after provisioning.
- `CatVox/Resources/Firebase/GoogleService-Info-<env>.plist` exists, is committed
  if that remains the chosen repo contract, and passes the automated plist check.
- A Release/App Store archive selects the environment, fails loudly if its plist
  is missing, and does not reference another environment's project IDs, bundle
  IDs, Debug App Check providers, or debug-token environment variables.
- Terraform plan output is reviewed by a human before any apply. A smoke run must
  never be used as approval to apply infrastructure.
- Cloud Run / Cloud Functions endpoints match the committed hosts, and the smoke
  GET checks return App Check rejection rather than signed upload URLs, quota
  reservations, or analysis responses.
- Firestore and GCS are inspected only through read/list/describe operations. Do
  not create test documents or upload objects.

## Failure Handling

If `CATVOX_ENVIRONMENT=<env> make smoke` fails after live values have landed:

1. Stop the release or cutover.
2. Keep the failed command output with the PR or release notes.
3. Fix configuration through a reviewed PR or revert the deploy path.
4. Re-run the smoke command after the fix. Do not substitute mutating integration
   tests for smoke.

For the full per-layer rollback procedures that step 3's "revert the deploy
path" refers to — app configuration, Functions, GitHub Environment secrets, and
Terraform changes — see `docs/CUTOVER_AND_ROLLBACK.md`.

If a check is skipped after the environment should be fully provisioned, re-run
with `CATVOX_SMOKE_REQUIRE_LIVE=1` to turn skips into failures and fix the missing
precondition.
