# Create a New CatVox Environment

This is the authoritative runbook for creating any named CatVox environment.
Environment names are data: scripts and code must not assume a fixed set of
environments exists. Behaviour differences between environments come from
`config/environments/<env>.xcconfig`, not from environment-specific code.

For one-time repository and GitHub Actions setup, see
`docs/CI_BOOTSTRAP.md`.

## Artifact Contract

Each environment owns these artifacts:

| Artifact | Location | Notes |
|---|---|---|
| App/runtime config | `config/environments/<env>.xcconfig` | Committed. Source of truth for non-secret app, backend, CI-auth identity, analytics, and Terraform environment values. Host fields store hostnames only, with no `https://`, path, or trailing slash. Do not put secrets or private operator values here. |
| Firebase iOS plist | `CatVox/Resources/Firebase/GoogleService-Info-<env>.plist` | Committed only after validation. The app loads the plist matching `CATVOX_ENVIRONMENT`. |

| Terraform variables | `terraform/env/<env>.tfvars` | Ignored. Contains only true secrets or deliberately private values: `app_check_debug_token` and `alert_email`. Commit only `.example` files. |
| GitHub Environment | `<env>` | Stores environment-scoped Actions secrets only. Mutable environments may be unprotected; protected environments must use a protected GitHub Environment. |
| Bundle ID | Terraform + xcconfig | Each environment sets its own bundle ID via `CATVOX_IOS_BUNDLE_ID`. |
| Apple Developer App ID | Apple Developer team | Conditional. Required only when the environment introduces a new iOS bundle ID that will be installed on physical devices or use App Attest. |
| App Check | Terraform | Mutable environments may have a Debug Provider token. Protected environments must not register debug tokens and use protected smoke checks only. |
| Backend URLs | `config/environments/<env>.xcconfig` | Set after Functions deploy from the deployed Gen 2 Function URLs. |
| PostHog config | `config/environments/<env>.xcconfig` | App-visible project token (`CATVOX_POSTHOG_PROJECT_TOKEN`), ingestion hostname (`CATVOX_POSTHOG_HOST_NAME`), Terraform API hostname (`CATVOX_POSTHOG_API_HOST_NAME`), PostHog project ID (`CATVOX_POSTHOG_PROJECT_ID`), and PostHog organization ID (`CATVOX_POSTHOG_ORGANIZATION_ID`). Create the environment's PostHog project before enabling real production analytics traffic. |
| PostHog Terraform state | `gs://catvox-tf-state-<gcp-project-id>/posthog/state` | Same GCS bucket as the GCP root, different prefix. No new bucket. See ADR-0020. |

PostHog environment isolation is project-based and maps 1:1 to CatVox
environments: each environment uses its own PostHog project, identified by the
PostHog values in `config/environments/<env>.xcconfig`
(`CATVOX_POSTHOG_PROJECT_TOKEN`, `CATVOX_POSTHOG_PROJECT_ID`). Never point one
environment at another environment's PostHog project as a stopgap. See ADR-0019
and ADR-0020.

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
| `CATVOX_PROJECT_ID` | `kathelix-catvox-dev` | Yes |
| `PROJECT_DISPLAY_NAME` | `Kathelix CatVox Dev` | Yes |
| `ORGANIZATION_ID` or `FOLDER_ID` | `1032067916665` | Optional, but usually needed for new projects |
| `BILLING_ACCOUNT_ID` | billing account ID | Optional; if omitted, link billing manually before deploy |
| `CATVOX_FUNCTION_REGION` | `us-central1` | Yes |
| `CATVOX_FIRESTORE_LOCATION` | `nam5` | Yes |
| `CATVOX_TF_STATE_BUCKET` | `catvox-tf-state-kathelix-catvox-dev` | Yes |
| `CATVOX_TF_STATE_PREFIX` | `catvox/state` | Yes |
| `CATVOX_IOS_BUNDLE_ID` | `com.kathelix.catvox.dev` | Yes |
| `CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME` | `CatVox Dev iOS` | Yes |
| `CATVOX_FIREBASE_IOS_APP_DELETION_POLICY` | `ABANDON` | Yes. Use `ABANDON` for protected environments; use `DELETE` only for disposable mutable environments. |
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
CATVOX_PROJECT_ID=<project-id> \
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
| `TF_VAR_APP_CHECK_DEBUG_TOKEN` | Mutable / integration-safe environments only |
| `POSTHOG_API_KEY` | PostHog scoped personal API key with project-write scope limited to this environment's PostHog project. |

Example:

```bash
gh api --method PUT repos/kathelix/catvox/environments/<env>
gh secret set TF_VAR_ALERT_EMAIL --env <env>
gh secret set TF_VAR_APP_CHECK_DEBUG_TOKEN --env <env>
gh secret set POSTHOG_API_KEY --env <env>
```

Protected environments must use a protected GitHub Environment and must not reuse
mutable-environment debug tokens or integration settings. Each environment's
`POSTHOG_API_KEY` must be a scoped PostHog personal API key limited to that
environment's PostHog project — never a shared org-admin key.

## Committed Environment Config

After Terraform apply and Functions deploy, update
`config/environments/<env>.xcconfig` with the environment's non-secret values:

```xcconfig
CATVOX_PROJECT_ID = <project-id>
CATVOX_ENVIRONMENT = <env>
CATVOX_ENVIRONMENT_PROTECTED = <true for protected environments; false for mutable environments>
CATVOX_FUNCTION_REGION = <region>
CATVOX_FIRESTORE_LOCATION = <firestore-location>
CATVOX_TF_STATE_BUCKET = catvox-tf-state-<project-id>
CATVOX_GCP_CI_SERVICE_ACCOUNT = <terraform output -raw ci_service_account_email>
CATVOX_GCP_WIF_PROVIDER = <terraform output -raw github_actions_wif_provider>
CATVOX_GCP_WIF_GITHUB_REF = <empty for any ref; a ref such as refs/heads/main for protected environments>
CATVOX_IOS_BUNDLE_ID = <bundle-id>
CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME = <display-name>
CATVOX_FIREBASE_IOS_APP_DELETION_POLICY = ABANDON
CATVOX_FIREBASE_APPLE_TEAM_ID = QYT76L5836
CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT = <UNENFORCED for mutable environments; ENFORCED for protected environments>

CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM = true
CATVOX_SIGNED_UPLOAD_URL_HOST = <getSignedUploadURL Cloud Run host only>
CATVOX_ANALYSE_VIDEO_HOST = <analyseVideo Cloud Run host only>
```

Keep `CATVOX_GCP_CI_SERVICE_ACCOUNT` and `CATVOX_GCP_WIF_PROVIDER` as full
strings, not composed pieces. **Note for App Check:** `config/environments/<env>.xcconfig` no longer requires App Check debug token boolean flags. The token itself in `terraform/env/<env>.tfvars` or the GitHub Environment secret determines registration.
Committed boolean values must be lowercase `true` or `false`; do not use `1`,
`0`, `yes`, or `no`.

**WIF ref scoping (`CATVOX_GCP_WIF_GITHUB_REF`).** WIF trust is always scoped to
the GitHub Environment whose name equals `CATVOX_ENVIRONMENT` (ADR-0024), so the
GitHub Environment name must match the CatVox environment name and every CI job
that authenticates must declare the matching `environment:`. Leave this key empty
to trust any ref. Set it to a ref such as `refs/heads/main` for a protected
environment so CI auth additionally requires `assertion.ref` to match.

**Firestore App Check (`CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT`).** One
of `OFF`, `UNENFORCED`, or `ENFORCED` (ADR-0025). Use `ENFORCED` for protected
environments (secure-by-default; Firebase client SDK access needs a valid App
Attest token) and `UNENFORCED` for mutable environments so the debug-token path
stays frictionless. Service-account / Admin SDK access (the backend SA and CI
integration probes via `@google-cloud/firestore`) bypasses App Check regardless
of this setting.

**Environment security tier (`CATVOX_ENVIRONMENT_PROTECTED`).** `true` for
protected environments, `false` for mutable environments (ADR-0026). When
`true`, `make ios-validate-env-config-structure`
(via `scripts/validate-environment-config.mjs`) enforces the protected posture:
App Check `ENFORCED`, a pinned `CATVOX_GCP_WIF_GITHUB_REF`, the `ABANDON`
deletion policy, and that the environment is absent from
`CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`. Validation and smoke are
environment-agnostic — run them with `CATVOX_ENVIRONMENT=<env>`; only the CI/CD
promotion pipeline names environments literally.

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

For protected environments:

- Do not include the environment in `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`.
- Do not run Firestore-mutating integration tests against it.
- Use only the protected, non-invasive smoke path in `docs/SMOKE_CHECKLIST.md`.

## Provisioning Into a Project That Already Has Resources

When an environment's GCP project already contains resources Terraform would
manage — most commonly a Firebase iOS app and the Firestore `(default)` database
(for example a project that was preserved or previously used) — those resources
must be imported into Terraform state before the first apply. Otherwise apply
fails with `ALREADY_EXISTS` when it tries to create them. Importing also
preserves an App Store-registered Firebase app ID and avoids Firestore
soft-delete/recreate delays.

`make environment-create` handles this automatically. After `terraform init` and
before `terraform plan`, it runs `scripts/import-preexisting-resources.sh`, which
idempotently imports the two resources Terraform creates (and would therefore
fail to re-create):

- **Firestore `(default)` database** (`google_firestore_database.default`) —
  imported when `gcloud firestore databases describe` finds it in the project.
- **Firebase iOS app** (`google_firebase_apple_app.ios`) — discovered by matching
  `CATVOX_IOS_BUNDLE_ID` (exact match) against the project's iOS apps from
  `firebase apps:list IOS`, then imported by the discovered app ID. The bundle id
  is the stable identifier in committed config; the app ID is a deferred
  placeholder until provisioning completes, so it is discovered rather than read
  from config.

The phase is idempotent and safe to re-run: a resource already in Terraform state
is skipped, and a resource absent from the project is left for apply to create
(so a brand-new environment is a no-op). It imports nothing destructive — it only
records existing resources in state — but it does write to remote state, so it
runs as part of provisioning rather than a pure read-only preview.

App Check singleton configs (`google_firebase_app_check_app_attest_config`,
`google_firebase_app_check_service_config`) are intentionally not imported: they
are PATCH-based singletons, so apply reconciles them via update rather than
failing to create.

Run the preview first (`RUN_TERRAFORM_APPLY=0`) to import and review the plan,
then re-run with `RUN_TERRAFORM_APPLY=1` to apply. For a protected environment
the first apply is operator-local because it also creates the Workload Identity
Federation pool and `catvox-ci-sa` that CI later authenticates as (ADR-0024);
subsequent applies go through the protected CI path.

## Operator Checklist: Standing Up a Protected Environment

This sequences the manual operator actions to bring a **protected** environment
(for example `prod`) fully online, end to end. The sections above cover each
piece in detail; this is the order to run them in. Every step is operator-run —
they need GCP-admin credentials, repo-admin rights, and the environment's secret
values, so they are not part of any PR diff or CI job.

Set these once for the session (substitute your environment):

```bash
export ENV=prod
export PROJECT_ID=kathelix-catvox-prod
```

**1 · First Terraform apply — operator-local (O1).** Run locally with GCP-admin
credentials: it creates the WIF pool and `catvox-ci-sa` that CI authenticates as,
and (for a preserved project) imports the existing Firebase app + Firestore
before applying. CI cannot do this — the CI SA has no `workloadIdentityPoolAdmin`
(see `docs/CI_BOOTSTRAP.md`). Functions are deliberately not deployed here;
protected environments deploy only through the protected CI path (step 6).

```bash
# Authenticate as the project's GCP admin first:
#   gcloud auth login && gcloud auth application-default login
CATVOX_ENVIRONMENT="$ENV" \
CATVOX_PROJECT_ID="$PROJECT_ID" \
PROJECT_DISPLAY_NAME="Kathelix CatVox Prod" \
CATVOX_FUNCTION_REGION=us-central1 \
CATVOX_FIRESTORE_LOCATION=nam5 \
CATVOX_TF_STATE_BUCKET="catvox-tf-state-$PROJECT_ID" \
CATVOX_TF_STATE_PREFIX=catvox/state \
CATVOX_IOS_BUNDLE_ID=com.kathelix.catvox \
CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME="CatVox Prod iOS" \
CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=ABANDON \
CATVOX_FIREBASE_APPLE_TEAM_ID=QYT76L5836 \
CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM=true \
ALERT_EMAIL=<prod-alerts@example.com> \
RUN_TERRAFORM_APPLY=1 \
RUN_FUNCTIONS_DEPLOY=0 \
make environment-create
```

**2 · Read the Firebase identity values and fill committed config.** The app's
`GOOGLE_APP_ID` and `API_KEY` exist only after step 1's apply, and the key
*value* is exposed only inside the generated plist (Terraform outputs the app id
and the key *id*, not the key value). Generate the plist once to read them — its
trailing validation fails while the xcconfig still holds `replace-with-…`
placeholders, which is expected on a brand-new environment, and the plist file is
written before that check runs:

```bash
CATVOX_ENVIRONMENT="$ENV" make terraform-output-firebase-plist || true
terraform -chdir=terraform output -raw firebase_ios_app_id    # → CATVOX_FIREBASE_APP_ID
plutil -extract API_KEY raw "CatVox/Resources/Firebase/GoogleService-Info-$ENV.plist"  # → CATVOX_FIREBASE_API_KEY
```

Put both into `config/environments/$ENV.xcconfig`, replacing the
`CATVOX_FIREBASE_APP_ID` and `CATVOX_FIREBASE_API_KEY` placeholders (see
"Committed Environment Config"). The two Cloud Run host placeholders are filled
after the deploy, in step 7.

**3 · Validate and commit the Firebase plist (O4).** Re-run the export — with the
identity values now in the xcconfig it validates — then commit the plist so the
iOS build for `$ENV` can load it:

```bash
CATVOX_ENVIRONMENT="$ENV" make terraform-output-firebase-plist
git add "CatVox/Resources/Firebase/GoogleService-Info-$ENV.plist" "config/environments/$ENV.xcconfig"
```

**4 · Create the protected GitHub Environment + required reviewer (O2).**
Repo-admin action. For `prod` the sole required reviewer is **Ivan Boyko**:

```bash
REVIEWER_ID=$(gh api users/IvanBoyko --jq .id)
gh api --method PUT repos/kathelix/catvox/environments/"$ENV" --input - <<JSON
{
  "reviewers": [{"type": "User", "id": ${REVIEWER_ID}}],
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
```

`protected_branches: true` requires `main` to be a protected branch; the WIF ref
pin (`CATVOX_GCP_WIF_GITHUB_REF=refs/heads/main`) already restricts this
environment's CI auth to `main` (ADR-0024). You can also set the reviewer from the
GitHub UI: Settings → Environments → `$ENV` → Required reviewers.

**5 · Set the environment's secrets (O3).** You supply the value when prompted.
Protected environments get **no** App Check debug token; PostHog
(`POSTHOG_API_KEY`) is deferred to #37 (see "GitHub Environment Secrets").

```bash
gh secret set TF_VAR_ALERT_EMAIL --env "$ENV" --repo kathelix/catvox
```

**6 · First Functions deploy — via the protected CI path.** Trigger the Functions
workflow manually from `main`; approve the `$ENV` Environment gate when GitHub
prompts you. (Ongoing Terraform changes promote the same way with
`terraform.yml`.)

```bash
gh workflow run functions.yml --ref main
# later, to promote infrastructure changes:
# gh workflow run terraform.yml --ref main
```

**7 · Fill backend host config + verify.** After the deploy, read the deployed
Cloud Run hosts and fill `CATVOX_SIGNED_UPLOAD_URL_HOST` /
`CATVOX_ANALYSE_VIDEO_HOST` in `config/environments/$ENV.xcconfig` (see "Update
App Config After Deploy"), then run the non-invasive smoke and follow
`docs/SMOKE_CHECKLIST.md`. Never run Firestore-mutating integration tests against
a protected environment.

```bash
CATVOX_ENVIRONMENT="$ENV" make smoke
```

**Ongoing.** Every later Terraform apply and Functions deploy goes through the
protected CI path (`gh workflow run … --ref main` → your approval on the `$ENV`
Environment). The one exception is WIF pool/provider/binding changes: apply those
operator-local before merge, because the CI SA cannot modify them (see
`docs/CI_BOOTSTRAP.md`).
