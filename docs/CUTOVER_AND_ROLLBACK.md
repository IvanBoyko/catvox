# Protected Environment Cutover and Rollback

This runbook covers taking a **protected** environment live (cutover) and backing
changes out (rollback). It is environment-agnostic: run every command with
`CATVOX_ENVIRONMENT=<env>`, with `prod` as the worked example. Environment names
are data; behaviour comes from `config/environments/<env>.xcconfig`, not from
environment-specific code (see ADR-0026).

It assumes the environment is already stood up per
`docs/CREATE_NEW_ENVIRONMENT.md` ("Operator Checklist: Standing Up a Protected
Environment"). This runbook is the next lifecycle phase: the final go/no-go
before public traffic, and how to recover each layer when something is wrong.

CatVox is an iOS app. "Enabling public traffic" means shipping the **Release**
build on the App Store — the Release configuration binds to the protected
environment at build time (`project.yml` maps `Release →
config/environments/prod.xcconfig`, and the build loads
`GoogleService-Info-$(CATVOX_ENVIRONMENT).plist`). There is no DNS or
load-balancer cutover. The single most important consequence runs through the
whole rollback section: a shipped App Store binary's embedded backend hosts and
project IDs **cannot** be rolled back remotely — only the backend
(Functions / Terraform / secrets) can.

Set the session variables once (substitute your environment):

```bash
export ENV=prod
export PROJECT_ID=kathelix-catvox-prod
# Region is data (config/environments/$ENV.xcconfig → CATVOX_FUNCTION_REGION);
# the raw gcloud commands below need it in the shell. For the prod example:
export CATVOX_FUNCTION_REGION=us-central1
```

## Pre-launch Cutover Checklist

Run this in order. The principle: the backend must be live, green, and verified
**before** the app binary that depends on it reaches users. Stop at the first
step that is not satisfied and resolve it.

1. **Backend is fully promoted to the protected environment.** Confirm both
   protected promotion paths have run end to end (this is the state issue #38
   Step 3 left the environment in). Promotion is split by tool until the delivery
   orchestrator (#106) unifies it:
   - **Terraform:** latest infrastructure applied via the manual dispatch,
     approved on the `$ENV` GitHub Environment — the `apply-prod` job in
     `.github/workflows/terraform.yml` (`gh workflow run terraform.yml --ref
     main`).
   - **Functions:** the `deploy-prod` job in `.github/workflows/functions.yml`
     (`needs: integration-after-deploy`) was approved at the `$ENV` Environment
     gate and is green. It runs only after the dev deploy and dev integration
     pass; approving the gate is the manual promote.
2. **Preflight the prerequisites (read-only).**

   ```bash
   CATVOX_ENVIRONMENT="$ENV" make environment-doctor
   ```

   Asserts the CI-SA roles (including `roles/cloudfunctions.admin`), the WIF
   trust chain, enabled APIs, billing, and the state bucket — so any gap surfaces
   now instead of mid-deploy.
3. **Backend host config is committed and matches the deployed functions.**
   Confirm `CATVOX_SIGNED_UPLOAD_URL_HOST` and `CATVOX_ANALYSE_VIDEO_HOST` in
   `config/environments/$ENV.xcconfig` are the live Cloud Run hosts.

   ```bash
   # Writes the deployed hosts (hostname only) into the working tree; review and
   # commit.
   CATVOX_ENVIRONMENT="$ENV" make environment-write-config PHASE=hosts
   ```

4. **Run the non-invasive smoke with skips promoted to failures.** Live values
   have landed, so nothing should skip.

   ```bash
   CATVOX_SMOKE_REQUIRE_LIVE=1 CATVOX_ENVIRONMENT="$ENV" make smoke
   ```

   Expected per `docs/SMOKE_CHECKLIST.md`: config and plist validate, the
   Terraform `plan -refresh-only` is clean, Firestore `(default)` is readable,
   and each backend GET returns `401 app_check_unauthorized` before business
   logic runs. On any failure, follow the smoke-failure path (see "Smoke-Failure
   Follow-up" below).
5. **Complete the manual operator checks** in `docs/SMOKE_CHECKLIST.md` →
   "Manual Operator Checks". In particular: the protected GitHub Environment
   exists with a required reviewer; the environment has **no**
   `TF_VAR_APP_CHECK_DEBUG_TOKEN` secret; App Check uses App Attest only with no
   Debug Provider token; `config/environments/$ENV.xcconfig` has no leftover
   `replace-with-*` placeholders; and a Release archive selects this environment
   and does not reference another environment's project IDs, bundle IDs, Debug
   App Check providers, or debug-token variables.
6. **Record the pre-launch data decision** (see "Pre-launch Data Handling"):
   Firestore, the uploads bucket, and the deployed function revisions inspected,
   with an explicit keep-or-clean decision noted alongside the release notes.
7. **Build, archive, and submit the Release build** for the protected bundle ID
   (`com.kathelix.catvox`). The Release configuration binds the protected
   environment automatically — do not pass an environment override. Archive and
   leak validation (no Dev endpoints, app IDs, debug tokens, or Debug provider
   paths in Release) is hardened in #38 Step 5; do not duplicate it here.
8. **Enable App Store traffic** — release the approved build, or begin the phased
   rollout. This is the point of no easy return for the *app* layer: everything
   above must be green first, because the embedded config is now frozen on
   users' devices (see "App configuration" under Rollback).

## Pre-launch Data Handling

Prod smoke is read-only, and Firestore-mutating integration tests never run
against a protected environment (it must be absent from
`CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`). So a protected environment should
already be free of test-generated data. This is a **verify-then-decide** step,
not a scheduled wipe. Default to **keep**; clean only what inspection shows is
genuine pre-launch test residue, and only with the decision recorded.

Inspect each surface with read-only operations:

| Surface | Read-only inspection | Default | Clean only if… |
|---|---|---|---|
| Firestore `(default)` | `gcloud firestore databases describe --database='(default)' --project "$PROJECT_ID"` plus a read-only console spot-check of collections | Keep | Inspection shows test/seed documents created before go-live |
| GCS uploads `catvox-raw-videos-$PROJECT_ID` | `gcloud storage ls "gs://catvox-raw-videos-$PROJECT_ID/**"` (list only) | Keep | Stray pre-launch uploaded objects exist |
| Cloud Run revisions | `gcloud run revisions list --region "$CATVOX_FUNCTION_REGION" --project "$PROJECT_ID"` | Keep all | n/a (see below) |

Per-surface notes:

- **Firestore.** If cleaning is chosen, delete the specific documents through the
  console or a reviewed admin script — never via integration tests, and never
  `terraform destroy` (that is teardown, not data cleanup). Deletion is
  irreversible; record exactly what was removed.
- **GCS.** The bucket is `force_destroy = false`, so accidental bucket deletion
  is blocked, but **object** deletes are permanent. If cleaning, remove specific
  objects (`gcloud storage rm "gs://catvox-raw-videos-$PROJECT_ID/<object>"`).
  Do not empty the bucket wholesale — that is the first step of teardown in
  `scripts/destroy-environment.sh` (it exists to let Terraform delete the
  bucket), not a launch action.
- **Function revisions.** Keep the current deployed revision; older revisions are
  harmless and are what makes the Functions rollback below possible, so do not
  prune them at cutover. `make functions-deploy` already sets a 7-day Artifact
  Registry cleanup policy (`firebase functions:artifacts:setpolicy`), so build
  artifacts age out on their own — nobody needs to hand-delete them.

This section uses only read / list / describe operations, consistent with
`docs/SMOKE_CHECKLIST.md` ("Firestore and GCS are inspected only through
read/list/describe operations").

## Rollback Procedures

The backend (Functions / Terraform / secrets) can be rolled back independently
of the app; the shipped app binary cannot. A Release binary embeds its backend
hosts and project IDs at build time, so once it is on a device those values are
frozen. The only app-layer levers are: halt or abandon a phased release,
expedite a corrected build through review, or pull the app from sale. Lean on
rolling back the **backend** — which you control directly — wherever that fixes
the problem without an app respin.

### App configuration

"App config" is `config/environments/$ENV.xcconfig` plus
`GoogleService-Info-$ENV.plist`, bound into the **Release** build via
`project.yml` (`Release → config/environments/prod.xcconfig`; the plist is
selected by `GoogleService-Info-$(CATVOX_ENVIRONMENT).plist`).

- **Before submission** (the binary is not yet shipped): revert the offending
  commit to the xcconfig or plist on a reviewed PR, then re-validate and rebuild.

  ```bash
  CATVOX_ENVIRONMENT="$ENV" make ios-validate-env-config
  CATVOX_ENVIRONMENT="$ENV" make smoke
  ```

- **After submission** (the binary is shipped): the embedded config is frozen in
  that build. Options, in order of preference: (1) **halt the phased release** in
  App Store Connect; (2) if the fault is server-side, fix the **backend** instead
  (see below) so the already-shipped app starts working again with no respin;
  (3) expedite a corrected build; (4) remove from sale as a last resort.
- **Caveat.** A shipped binary's embedded hosts and project IDs cannot be
  un-shipped.

### Functions deployment

- **Forward-fix (preferred, matches the protected pipeline).** Revert the
  offending change on a reviewed PR to `main`. On merge it auto-deploys to dev
  and runs dev integration, then **re-promote** by approving the `deploy-prod`
  gate on the `$ENV` Environment — the same path as the original promote in
  `.github/workflows/functions.yml`.
- **Emergency stop (a bad revision must stop serving immediately).** Shift Cloud
  Run traffic back to the prior known-good revision. `<service>` is the function
  name (`getSignedUploadURL` or `analyseVideo`); list revisions with `gcloud run
  revisions list --service <service> --region "$CATVOX_FUNCTION_REGION"
  --project "$PROJECT_ID"`.

  ```bash
  gcloud run services update-traffic <service> \
    --region "$CATVOX_FUNCTION_REGION" \
    --project "$PROJECT_ID" \
    --to-revisions <PRIOR_REVISION>=100
  ```

  This is why "Pre-launch Data Handling" keeps old revisions. Afterwards, land
  the forward-fix through the protected path so the repository state and the
  serving revision reconverge.
- **Caveat.** Even a rollback deploy is gated — it is still a human approval at
  the `$ENV` Environment, not automatic.

### GitHub Environment secrets

Secrets in scope on the `$ENV` Environment: `TF_VAR_ALERT_EMAIL` and
`POSTHOG_API_KEY` (a protected environment carries **no**
`TF_VAR_APP_CHECK_DEBUG_TOKEN`). Re-set the prior value:

```bash
gh secret set <NAME> --env "$ENV" --repo kathelix/catvox
```

- **Caveat — write-only.** GitHub will not show the old value, so the operator
  must already know the correct prior value (keep it in your secret store, not in
  the repository).
- **Caveat — not live until consumed.** A secret change does not take effect
  until the next apply or deploy reads it. `terraform-apply.yml` and
  `functions-deploy.yml` consume these via `secrets: inherit` at run time, so
  after re-setting a secret you must re-run the relevant protected apply or
  deploy to actually roll the behaviour back.

### Terraform changes

- **Forward-fix.** Revert the offending Terraform commit on a reviewed PR; the PR
  gets the automatic dev plan/apply, and prod re-applies through the manual
  dispatch approved on the `$ENV` Environment.

  ```bash
  gh workflow run terraform.yml --ref main   # apply-prod, then approve the gate
  ```

- **Caveat — state is recoverable, side effects are not.** Terraform state lives
  in the versioned GCS bucket `catvox-tf-state-$PROJECT_ID` (object versioning
  on, per ADR-0004), so a corrupted state object can be restored to a prior
  generation. But reverting `.tf` and re-applying *reconciles* live resources —
  it does not undo destructive side effects (a deleted Firestore database or an
  emptied bucket does not come back from a config revert).
- **Caveat — WIF changes are operator-local.** Any rollback that touches the WIF
  pool, provider, or `ci_sa_wif_binding` must be applied operator-local **before**
  merge — the CI SA lacks `workloadIdentityPoolAdmin`, and routing a WIF change
  through CI destroys the binding and breaks authentication for the whole
  environment until an operator-local
  `make terraform-apply CATVOX_ENVIRONMENT="$ENV" CONFIRM=apply` reconciles it
  (see `docs/CI_BOOTSTRAP.md` → "WIF Trust Model").
- **Caveat — smoke is not apply-approval.** Re-run `make smoke` after the
  rollback applies, but a green smoke is verification, never authorization to
  apply (per `docs/SMOKE_CHECKLIST.md`).

## Smoke-Failure Follow-up

If `CATVOX_ENVIRONMENT=<env> make smoke` fails during cutover, follow
`docs/SMOKE_CHECKLIST.md` → "Failure Handling": **stop the release/cutover**,
keep the failed output with the PR or release notes, fix through a reviewed PR
**or revert the deploy path**, and re-run smoke. Never substitute mutating
integration tests for smoke.

"Revert the deploy path" maps directly to the rollback sections above:

- A bad **Functions** deploy → "Functions deployment".
- A bad **Terraform** apply → "Terraform changes".
- A bad **secret** → "GitHub Environment secrets".
- Bad **app config** caught before submission → "App configuration".

The quick follow-up path is the same protected promotion path used in reverse: a
fix or revert PR → dev auto-deploy and dev integration → re-approve the
`deploy-prod` gate (Functions) and/or re-dispatch and approve `apply-prod`
(Terraform). Because the protected path is approval-gated, the follow-up is fast
but still gated on a human approval at the `$ENV` Environment — there is no
auto-rollback, by design.

If a check is **skipped** when it should be live, re-run with
`CATVOX_SMOKE_REQUIRE_LIVE=1` and fix the missing precondition before continuing
the cutover.
