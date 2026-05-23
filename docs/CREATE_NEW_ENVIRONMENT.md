# Create a New CatVox Environment

This is the authoritative runbook for creating a named CatVox environment such as
`dev`, `prod`, `staging`, or another future name. Environment names are data:
scripts and code must not assume only `dev` and `prod` exist.

For one-time repository and GitHub Actions setup, see
`docs/CI_BOOTSTRAP.md`.

## Artifact Contract

Each environment owns these artifacts:

| Artifact | Location | Notes |
|---|---|---|
| App/runtime config | `config/environments/<env>.xcconfig` | Committed. Source of truth for non-secret app, backend, CI-auth identity, analytics, and Terraform environment values. Host fields store hostnames only, with no `https://`, path, or trailing slash. Do not put secrets or private operator values here. |
| Firebase iOS plist | `CatVox/Resources/Firebase/GoogleService-Info-<env>.plist` | Committed only after validation. The app loads the plist matching `CATVOX_ENVIRONMENT`. |

| Terraform variables | `terraform/env/<env>.tfvars` | Ignored. Contains only true secrets or deliberately private values: `app_check_debug_token` and `alert_email`. Commit only `.example` files. |
| GitHub Environment | `<env>` | Stores environment-scoped Actions secrets only. Dev can be unprotected; future Prod must be explicitly protected. |
| Bundle ID | Terraform + xcconfig | Dev currently uses `com.kathelix.catvox.dev`; future App Store Prod uses `com.kathelix.catvox`. |
| Apple Developer App ID | Apple Developer team | Conditional. Required only when the environment introduces a new iOS bundle ID that will be installed on physical devices or use App Attest. |
| App Check | Terraform | Dev may have a Debug Provider token. Prod must not have mutable integration debug tokens and should use protected smoke checks only. |
| Backend URLs | `config/environments/<env>.xcconfig` | Set after Functions deploy from the deployed Gen 2 Function URLs. |
| PostHog config | `config/environments/<env>.xcconfig` | App-visible project token (`CATVOX_POSTHOG_PROJECT_TOKEN`), ingestion hostname (`CATVOX_POSTHOG_HOST_NAME`), Terraform API hostname (`CATVOX_POSTHOG_API_HOST_NAME`), PostHog project ID (`CATVOX_POSTHOG_PROJECT_ID`), and PostHog organization ID (`CATVOX_POSTHOG_ORGANIZATION_ID`). Create the environment's PostHog project before enabling real production analytics traffic. |
| PostHog Terraform state | `gs://catvox-tf-state-<gcp-project-id>/posthog/state` | Same GCS bucket as the GCP root, different prefix. No new bucket. See ADR-0020. |

PostHog environment isolation is project-based and maps 1:1 to CatVox
environments. Dev uses the `CatVox Dev` PostHog project, and real production
analytics require a dedicated `CatVox Prod` PostHog project before App Store
production traffic is enabled. Do not point a real environment at the existing
Dev PostHog project as a stopgap. See ADR-0019 and ADR-0020.

Keep personal/API credentials and private operator values out of app config.
`POSTHOG_API_KEY`, `TF_VAR_APP_CHECK_DEBUG_TOKEN`, and `TF_VAR_ALERT_EMAIL` live
in the matching per-environment GitHub Environment as secrets. Non-secret
environment values live in `config/environments/<env>.xcconfig`, including the
GCP project ID, full CI service account email, full WIF provider resource name,
GCP/Firebase Terraform inputs, PostHog Terraform identifiers, and app runtime
values. The Makefile reads this file for local and CI automation. See ADR-0021.

## Inputs

Pick explicit values before running the script:

| Variable | Example | Required |
|---|---|---|
| `CATVOX_ENVIRONMENT` | `dev` | Yes |
| `GCP_PROJECT_ID` | `kathelix-catvox-dev` | Yes |
| `PROJECT_DISPLAY_NAME` | `Kathelix CatVox Dev` | Yes |
| `ORGANIZATION_ID` or `FOLDER_ID` | `1032067916665` | Optional, but usually needed for new projects |
| `BILLING_ACCOUNT_ID` | billing account ID | Optional; if omitted, link billing manually before deploy |
| `CATVOX_FUNCTION_REGION` | `us-central1` | Yes |
| `CATVOX_FIRESTORE_LOCATION` | `nam5` | Yes |
| `CATVOX_TF_STATE_BUCKET` | `catvox-tf-state-kathelix-catvox-dev` | Yes |
| `CATVOX_TF_STATE_PREFIX` | `catvox/state` | Yes |
| `CATVOX_IOS_BUNDLE_ID` | `com.kathelix.catvox.dev` | Yes |
| `CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME` | `CatVox Dev iOS` | Yes |
| `CATVOX_FIREBASE_IOS_APP_DELETION_POLICY` | `ABANDON` | Yes. Use `ABANDON` for Prod-like environments; use `DELETE` only for disposable Dev-like environments. |
| `CATVOX_FIREBASE_APPLE_TEAM_ID` | `QYT76L5836` | Yes |
| `CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM` | `true` for Dev bootstrap | Yes. Use lowercase `true` or `false` only. |
| `APP_CHECK_DEBUG_TOKEN` | UUID4 token | Optional. Presence registers the token. |
| `ALERT_EMAIL` | alert recipient | Required when the ignored tfvars file does not already exist |
| `RUN_TERRAFORM_APPLY` | `0` or `1` | Yes. Set to `1` to apply Terraform; `0` runs only the safe preview phases. |
| `RUN_FUNCTIONS_DEPLOY` | `0` or `1` | Yes. Set to `1` to deploy Cloud Functions; `0` skips the deploy. |

## Automated Creation

From the repository root:

```bash
CATVOX_ENVIRONMENT=<env> \
GCP_PROJECT_ID=<project-id> \
PROJECT_DISPLAY_NAME="Kathelix CatVox <Env>" \
ORGANIZATION_ID=<org-id> \
BILLING_ACCOUNT_ID=<billing-account-id> \
CATVOX_FUNCTION_REGION=us-central1 \
CATVOX_FIRESTORE_LOCATION=nam5 \
CATVOX_TF_STATE_BUCKET=catvox-tf-state-<project-id> \
CATVOX_TF_STATE_PREFIX=catvox/state \
CATVOX_IOS_BUNDLE_ID=<bundle-id> \
CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME="CatVox <Env> iOS" \
CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=ABANDON \
CATVOX_FIREBASE_APPLE_TEAM_ID=QYT76L5836 \
CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM=true \
ALERT_EMAIL=<alerts@example.com> \
RUN_TERRAFORM_APPLY=1 \
RUN_FUNCTIONS_DEPLOY=1 \
make environment-create
```

If you are bootstrapping an environment that allows mutable integration tests,
pass `APP_CHECK_DEBUG_TOKEN=<your-uuid4>`.

The script:

1. Creates or verifies the GCP project.
2. Links billing when `BILLING_ACCOUNT_ID` is provided.
3. Enables Firebase on the project.
4. Bootstraps the GCS Terraform state bucket with versioning.
5. Creates the Cloud Functions Gen 2 source bucket so Terraform can manage its IAM before the first deploy.
6. Creates secrets-only `terraform/env/<env>.tfvars` if it does not already exist.
7. Runs Terraform init and plan.
8. Optionally applies Terraform.
9. Writes and validates `CatVox/Resources/Firebase/GoogleService-Info-<env>.plist`.
10. Optionally sets the Functions artifact cleanup policy and deploys Cloud Functions.
11. Prints the remaining GitHub Environment secrets and committed xcconfig values still needing review.

Both `RUN_TERRAFORM_APPLY` and `RUN_FUNCTIONS_DEPLOY` must be set explicitly to
either `0` or `1` — there are no defaults. Set them to `0` to stop after the
safe preview phases.

## GitHub Environment Secrets

Create or update the GitHub Environment named `<env>` and set:

| Secret | Value |
|---|---|
| `TF_VAR_ALERT_EMAIL` | same value as `alert_email` in ignored tfvars |
| `TF_VAR_APP_CHECK_DEBUG_TOKEN` | Dev/integration-safe environments only |
| `POSTHOG_API_KEY` | PostHog scoped personal API key with project-write scope limited to this environment's PostHog project. |

Example:

```bash
gh api --method PUT repos/kathelix/catvox/environments/<env>
gh secret set TF_VAR_ALERT_EMAIL --env <env>
gh secret set TF_VAR_APP_CHECK_DEBUG_TOKEN --env <env>
gh secret set POSTHOG_API_KEY --env <env>
```

Future Prod must use a protected GitHub Environment and must not reuse Dev debug
tokens or mutable integration settings. Each environment's `POSTHOG_API_KEY`
must be a scoped PostHog personal API key limited to that environment's PostHog
project — never a shared org-admin key.

## Committed Environment Config

After Terraform apply and Functions deploy, update
`config/environments/<env>.xcconfig` with the environment's non-secret values:

```xcconfig
GCP_PROJECT_ID = <project-id>
FIREBASE_PROJECT = <project-id>
CATVOX_PROJECT_ID = <project-id>
CATVOX_ENVIRONMENT = <env>
CATVOX_FUNCTION_REGION = <region>
CATVOX_FIRESTORE_LOCATION = <firestore-location>
CATVOX_TF_STATE_BUCKET = catvox-tf-state-<project-id>
CATVOX_GCP_CI_SERVICE_ACCOUNT = <terraform output -raw ci_service_account_email>
CATVOX_GCP_WIF_PROVIDER = <terraform output -raw github_actions_wif_provider>
CATVOX_PRODUCT_BUNDLE_IDENTIFIER = <bundle-id>
CATVOX_IOS_BUNDLE_ID = <bundle-id>
CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME = <display-name>
CATVOX_FIREBASE_IOS_APP_DELETION_POLICY = ABANDON
CATVOX_FIREBASE_APPLE_TEAM_ID = QYT76L5836

CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM = true
CATVOX_SIGNED_UPLOAD_URL_HOST = <getSignedUploadURL Cloud Run host only>
CATVOX_ANALYSE_VIDEO_HOST = <analyseVideo Cloud Run host only>
```

Keep `CATVOX_GCP_CI_SERVICE_ACCOUNT` and `CATVOX_GCP_WIF_PROVIDER` as full
strings, not composed pieces. **Note for App Check:** `config/environments/<env>.xcconfig` no longer requires App Check debug token boolean flags. The token itself in `terraform/env/<env>.tfvars` or the GitHub Environment secret determines registration.
Committed boolean values must be lowercase `true` or `false`; do not use `1`,
`0`, `yes`, or `no`.

## Conditional Apple Developer Bundle Setup

Most environment creation is cloud/Firebase setup and does not require changing
local Xcode signing. Skip this section when the new environment reuses an
existing iOS bundle ID or when developers will continue to build only the active
Dev bundle locally.

Run this section only when `CATVOX_IOS_BUNDLE_ID` is a new explicit bundle ID
that needs physical-device builds or App Attest configuration. This is manual
unless an Apple Developer API integration is added later.

1. In the Apple Developer account for team `QYT76L5836`, create or verify an
   explicit App ID for `CATVOX_IOS_BUNDLE_ID`.
2. Enable the App Attest capability for that App ID. CatVox's entitlements use
   `com.apple.developer.devicecheck.appattest-environment = production`.
3. Let automatic signing create the development provisioning profile, or create
   an iOS App Development profile manually for the exact bundle ID and selected
   test devices.
4. Keep signing settings in `project.yml`. Do not hand-edit
   `CatVox.xcodeproj`; regenerate it with `make ios-generate`.
5. Install and launch on the selected device:
   ```bash
   CATVOX_ENVIRONMENT=<env> \
   DEVICE_ID=<device-udid> \
   make ios-device-launch
   ```

If Xcode shows `Unknown Name (QYT76L5836)` or `No Accounts`, that is local
workstation setup, not an environment artifact. Add an Apple Developer account
in Xcode Settings → Accounts and verify it can access team `QYT76L5836`; see
`docs/DEBUG.md`.

## Update App Config After Deploy

After Functions deploy, update host-only values in
`config/environments/<env>.xcconfig`:

```bash
gcloud functions describe getSignedUploadURL \
  --v2 \
  --project <project-id> \
  --region us-central1 \
  --format='value(serviceConfig.uri)'

gcloud functions describe analyseVideo \
  --v2 \
  --project <project-id> \
  --region us-central1 \
  --format='value(serviceConfig.uri)'
```

Strip `https://` and store only the hostname.

Then validate:

```bash
CATVOX_ENVIRONMENT=<env> make ios-validate-env-config
```

## Required Validation

For Dev-like mutable environments:

```bash
export CATVOX_ENVIRONMENT=<env>

make functions-test
make terraform-plan
make posthog-terraform-plan
make ios-generate
make ios-test
make functions-integration
```

The Terraform tfvars basename must match `CATVOX_ENVIRONMENT`; the
Makefile rejects mismatched tfvars paths.

Also run a real Debug device scan before retiring or cleaning any previous Dev
backend.

For future Prod:

- Do not include Prod in `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`.
- Do not run Firestore-mutating integration tests.
- Use only the protected, non-invasive smoke path in
  `docs/PROD_SMOKE_CHECKLIST.md`.
- When creating real Prod in preserved `kathelix-catvox-prod`, start from
  `docs/archive/LEGACY_PRESPLIT_CLEANUP_REPORT_2026-05-16.md`: the Firebase iOS app
  for `com.kathelix.catvox` and the empty Firestore `(default)` database were
  intentionally preserved, so the Prod slice must either import them into
  Terraform state or deliberately delete/recreate them after confirming the
  recreation behavior.

## Legacy Pre-Split Project Cleanup

Do not delete `kathelix-catvox-prod`. Keeping the project container avoids any
project-ID deletion and recreation delay before the future real Prod slice.

After the new Dev environment has passed deploy, integration, and a Debug device
scan:

1. Verify active code and workflows no longer point at `kathelix-catvox-prod`
   except legacy cleanup docs/scripts:
   ```bash
   rg "kathelix-catvox-prod" \
     --glob '!docs/CREATE_NEW_ENVIRONMENT.md' \
     --glob '!scripts/cleanup-legacy-presplit-project.sh'
   ```
2. Verify the GitHub Environment `dev` secrets point at the new Dev project.
3. Confirm the ignored legacy tfvars file exists while the old state bucket still exists:
   `terraform/env/legacy-presplit.tfvars`.
4. Run an explicit old-project destroy using the legacy tfvars (the Makefile will auto-inject the backend bucket args):
   ```bash
   CATVOX_ENVIRONMENT=legacy-presplit \
   GCP_PROJECT_ID=kathelix-catvox-prod \
   CATVOX_TF_VARS_FILE=terraform/env/legacy-presplit.tfvars \
   make terraform-plan

   CATVOX_ENVIRONMENT=legacy-presplit \
   GCP_PROJECT_ID=kathelix-catvox-prod \
   CATVOX_TF_VARS_FILE=terraform/env/legacy-presplit.tfvars \
   terraform -chdir=terraform destroy -var-file=env/legacy-presplit.tfvars
   ```
5. Sweep non-Terraform leftovers without deleting the project:
   ```bash
   CONFIRM=cleanup-kathelix-catvox-prod ./scripts/cleanup-legacy-presplit-project.sh
   ```
6. Record a cleanup report before future Prod work. The report should confirm no old debug tokens, Functions, CatVox custom service accounts, CatVox buckets, active state objects, or GitHub Dev secrets remain tied to `kathelix-catvox-prod`.
