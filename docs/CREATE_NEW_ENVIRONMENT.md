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
| App/runtime config | `config/environments/<env>.xcconfig` | Committed. Host fields store hostnames only, with no `https://`, path, or trailing slash. Do not put Terraform-only secrets here. |
| Firebase iOS plist | `CatVox/Resources/Firebase/GoogleService-Info-<env>.plist` | Committed only after validation. The app loads the plist matching `CATVOX_ENVIRONMENT`. |
| Terraform backend config | `terraform/backend/<env>.hcl` | Ignored. Contains the remote state bucket and prefix. Commit only `.example` files. |
| Terraform variables | `terraform/env/<env>.tfvars` | Ignored. Contains Terraform-only inputs and secrets such as `app_check_debug_token`, `alert_email`, Firestore location, App Check settings, and source-bucket IAM switch. Commit only `.example` files. |
| GitHub Environment | `<env>` | Stores environment-scoped Actions secrets. Dev can be unprotected; future Prod must be explicitly protected. |
| Bundle ID | Terraform + xcconfig | Dev currently uses `com.kathelix.catvox.dev`; future App Store Prod uses `com.kathelix.catvox`. |
| Apple Developer App ID | Apple Developer team | Conditional. Required only when the environment introduces a new iOS bundle ID that will be installed on physical devices or use App Attest. |
| App Check | Terraform | Dev may have a Debug Provider token. Prod must not have mutable integration debug tokens and should use protected smoke checks only. |
| Backend URLs | `config/environments/<env>.xcconfig` | Set after Functions deploy from the deployed Gen 2 Function URLs. |
| PostHog config | `config/environments/<env>.xcconfig` | App-visible project token (`CATVOX_POSTHOG_PROJECT_TOKEN`), ingestion hostname (`CATVOX_POSTHOG_HOST_NAME`), Terraform API hostname (`CATVOX_POSTHOG_API_HOST_NAME`), and PostHog project ID for Terraform (`CATVOX_POSTHOG_PROJECT_ID`). Create the environment's PostHog project before enabling real production analytics traffic. |
| PostHog Terraform state | `gs://catvox-tf-state-<gcp-project-id>/posthog/state` | Same GCS bucket as the GCP root, different prefix. No new bucket. See ADR-0020. |

PostHog environment isolation is project-based and maps 1:1 to CatVox
environments. Dev uses the `CatVox Dev` PostHog project, and real production
analytics require a dedicated `CatVox Prod` PostHog project before App Store
production traffic is enabled. Do not point a real environment at the existing
Dev PostHog project as a stopgap. See ADR-0019 and ADR-0020.

Keep PostHog personal/API credentials out of app config. PostHog Terraform
operational secrets — `POSTHOG_API_KEY` and `POSTHOG_ORGANIZATION_ID` — live in
the matching per-environment GitHub Environment as secrets. The PostHog API host
and project ID live only in `config/environments/<env>.xcconfig` as
`CATVOX_POSTHOG_API_HOST_NAME` and `CATVOX_POSTHOG_PROJECT_ID` so app config
remains the source of truth for Makefile-driven `posthog-terraform-*` targets
and CI.

## Inputs

Pick explicit values before running the script:

| Variable | Example | Required |
|---|---|---|
| `CATVOX_ENVIRONMENT` | `dev` | Yes |
| `GCP_PROJECT_ID` | `kathelix-catvox-dev` | Yes |
| `PROJECT_DISPLAY_NAME` | `Kathelix CatVox Dev` | Optional |
| `ORGANIZATION_ID` or `FOLDER_ID` | `1032067916665` | Optional, but usually needed for new projects |
| `BILLING_ACCOUNT_ID` | billing account ID | Optional; if omitted, link billing manually before deploy |
| `CATVOX_IOS_BUNDLE_ID` | `com.kathelix.catvox.dev` | Yes |
| `FIREBASE_IOS_APP_DELETION_POLICY` | `ABANDON` | Optional. Keep default for Prod-like environments; use `DELETE` only for disposable Dev-like environments. |
| `APP_CHECK_DEBUG_TOKEN` | UUID4 token | Dev only |
| `ALERT_EMAIL` | alert recipient | Yes for Terraform apply |

## Automated Creation

From the repository root:

```bash
CATVOX_ENVIRONMENT=<env> \
GCP_PROJECT_ID=<project-id> \
PROJECT_DISPLAY_NAME="Kathelix CatVox <Env>" \
ORGANIZATION_ID=<org-id> \
BILLING_ACCOUNT_ID=<billing-account-id> \
CATVOX_IOS_BUNDLE_ID=<bundle-id> \
FIREBASE_IOS_APP_DELETION_POLICY=ABANDON \
APP_CHECK_DEBUG_TOKEN=<uuid4-debug-token> \
ALERT_EMAIL=<alerts@example.com> \
RUN_TERRAFORM_APPLY=1 \
RUN_FUNCTIONS_DEPLOY=1 \
make environment-create
```

The script:

1. Creates or verifies the GCP project.
2. Links billing when `BILLING_ACCOUNT_ID` is provided.
3. Enables Firebase on the project.
4. Bootstraps the GCS Terraform state bucket with versioning.
5. Creates the Cloud Functions Gen 2 source bucket so Terraform can manage its IAM before the first deploy.
6. Creates ignored `terraform/backend/<env>.hcl` and `terraform/env/<env>.tfvars` if they do not already exist.
7. Runs Terraform init and plan.
8. Optionally applies Terraform.
9. Writes and validates `CatVox/Resources/Firebase/GoogleService-Info-<env>.plist`.
10. Optionally sets the Functions artifact cleanup policy and deploys Cloud Functions.
11. Prints the GitHub Environment secrets and app config values still needing review.

If you do not pass `RUN_TERRAFORM_APPLY=1` or `RUN_FUNCTIONS_DEPLOY=1`, the script
stops after the safe preview phases.

## GitHub Environment Secrets

Create or update the GitHub Environment named `<env>` and set:

| Secret | Value |
|---|---|
| `GCP_PROJECT_ID` | `<project-id>` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `terraform output -raw github_actions_wif_provider` |
| `GCP_SERVICE_ACCOUNT` | `terraform output -raw ci_service_account_email` |
| `TF_VAR_ALERT_EMAIL` | same value as `alert_email` in ignored tfvars |
| `TF_VAR_APP_CHECK_DEBUG_TOKEN` | Dev/integration-safe environments only |
| `POSTHOG_API_KEY` | PostHog scoped personal API key with project-write scope limited to this environment's PostHog project. |
| `POSTHOG_ORGANIZATION_ID` | UUID of the PostHog organisation containing the project. |

Example:

```bash
gh api --method PUT repos/kathelix/catvox/environments/<env>
gh secret set GCP_PROJECT_ID --env <env> --body <project-id>
gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --env <env> --body "$(terraform -chdir=terraform output -raw github_actions_wif_provider)"
gh secret set GCP_SERVICE_ACCOUNT --env <env> --body "$(terraform -chdir=terraform output -raw ci_service_account_email)"
gh secret set TF_VAR_ALERT_EMAIL --env <env>
gh secret set TF_VAR_APP_CHECK_DEBUG_TOKEN --env <env>
gh secret set POSTHOG_API_KEY --env <env>
gh secret set POSTHOG_ORGANIZATION_ID --env <env>
```

Future Prod must use a protected GitHub Environment and must not reuse Dev debug
tokens or mutable integration settings. Each environment's `POSTHOG_API_KEY`
must be a scoped PostHog personal API key limited to that environment's PostHog
project — never a shared org-admin key.

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
   CATVOX_ENV_CONFIG=config/environments/<env>.xcconfig \
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
CATVOX_ENV_CONFIG=config/environments/<env>.xcconfig make ios-validate-env-config
```

## Required Validation

For Dev-like mutable environments:

```bash
make functions-test
CATVOX_TERRAFORM_ENV=<env> make terraform-plan
CATVOX_ENV_CONFIG=config/environments/<env>.xcconfig CATVOX_TERRAFORM_ENV=<env> make posthog-terraform-plan
CATVOX_ENV_CONFIG=config/environments/<env>.xcconfig make ios-generate
CATVOX_ENV_CONFIG=config/environments/<env>.xcconfig make ios-test
CATVOX_ENV_CONFIG=config/environments/<env>.xcconfig make functions-integration
```

Also run a real Debug device scan before retiring or cleaning any previous Dev
backend.

For future Prod:

- Do not include Prod in `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`.
- Do not run Firestore-mutating integration tests.
- Use a protected manual smoke-test checklist only.
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
3. Recreate ignored legacy backend/tfvars files while the old state bucket still exists:
   ```hcl
   # terraform/backend/legacy-presplit.hcl
   bucket = "catvox-tf-state-kathelix-catvox-prod"
   prefix = "catvox/state"
   ```
4. Run an explicit old-project destroy using the legacy backend and tfvars:
   ```bash
   CATVOX_TERRAFORM_ENV=legacy-presplit \
   GCP_PROJECT_ID=kathelix-catvox-prod \
   CATVOX_TF_BACKEND_CONFIG=terraform/backend/legacy-presplit.hcl \
   CATVOX_TF_VARS_FILE=terraform/env/legacy-presplit.tfvars \
   make terraform-plan

   CATVOX_TERRAFORM_ENV=legacy-presplit \
   GCP_PROJECT_ID=kathelix-catvox-prod \
   CATVOX_TF_BACKEND_CONFIG=terraform/backend/legacy-presplit.hcl \
   CATVOX_TF_VARS_FILE=terraform/env/legacy-presplit.tfvars \
   terraform -chdir=terraform destroy -var-file=env/legacy-presplit.tfvars
   ```
5. Sweep non-Terraform leftovers without deleting the project:
   ```bash
   CONFIRM=cleanup-kathelix-catvox-prod ./scripts/cleanup-legacy-presplit-project.sh
   ```
6. Record a cleanup report before future Prod work. The report should confirm no old debug tokens, Functions, CatVox custom service accounts, CatVox buckets, active state objects, or GitHub Dev secrets remain tied to `kathelix-catvox-prod`.
