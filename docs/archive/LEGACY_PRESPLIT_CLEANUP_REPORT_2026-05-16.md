# Legacy Pre-Split Cleanup Report — 2026-05-16

## Scope

This report records cleanup of Dev leftovers from the preserved
`kathelix-catvox-prod` GCP/Firebase project after active Dev moved to
`kathelix-catvox-dev`.

The `kathelix-catvox-prod` project container was intentionally not deleted. It
remains reserved for the future real Prod slice.

## Gate

Cleanup started only after the new Dev environment had passed deploy,
integration, and device-backed backend proof:

| Check | Result |
|---|---|
| New Dev Functions deploy | `getSignedUploadURL` and `analyseVideo` active in `kathelix-catvox-dev` |
| New Dev integration tests | Passed with mutable Firestore checks against `kathelix-catvox-dev` |
| Device-backed backend proof | `kathelix-catvox-dev` request logs showed `getSignedUploadURL` HTTP 200 at `2026-05-16T11:24:35Z` and `analyseVideo` HTTP 200 at `2026-05-16T11:24:40Z` |
| Dev Terraform state after cleanup | `CATVOX_TERRAFORM_ENV=dev make terraform-plan` reported `No changes` |

## Cleanup Performed

| Area | Action |
|---|---|
| Terraform-managed legacy resources | Ran a legacy pre-split destroy against `catvox-tf-state-kathelix-catvox-prod/catvox/state`; result: `45 destroyed` |
| Old raw video bucket | Deleted remaining uploaded video objects before Terraform destroyed `catvox-raw-videos-kathelix-catvox-prod` |
| Old Functions | Deleted `analyseVideo` and `getSignedUploadURL` from `kathelix-catvox-prod` |
| Old Functions staging buckets | Deleted `gcf-v2-sources-953500951129-us-central1` and `gcf-v2-uploads-953500951129.us-central1.cloudfunctions.appspot.com` |
| Old Artifact Registry repos | Deleted Terraform-managed `catvox-functions` and auto-created `gcf-artifacts` |
| Old custom service accounts | Deleted `catvox-backend-sa@kathelix-catvox-prod.iam.gserviceaccount.com` and `catvox-ci-sa@kathelix-catvox-prod.iam.gserviceaccount.com` |
| Old WIF | Deleted `github-actions-pool` from `kathelix-catvox-prod` |
| Old secrets | Deleted `GCP_PROJECT_ID` and `APP_CHECK_DEBUG_TOKEN` Secret Manager secrets |
| Old App Check debug tokens | Deleted the remaining Firebase App Check debug token for the preserved Firebase iOS app |
| Old Firestore Dev data | Bulk-deleted the CatVox `usage` collection group |
| Old Terraform state bucket | Deleted `catvox-tf-state-kathelix-catvox-prod` including object versions and lock objects |
| Local legacy tfvars | Removed obsolete ignored `terraform/terraform.tfvars`; active local Terraform input is `terraform/env/dev.tfvars` |

## Verification

Post-cleanup checks for `kathelix-catvox-prod` showed:

| Check | Result |
|---|---|
| Project lifecycle | `ACTIVE`; project container preserved |
| Cloud Functions | No functions listed |
| Cloud Run services | No services listed in `us-central1` |
| GCS buckets | No buckets listed |
| Artifact Registry repos | No repositories listed in `us-central1` |
| Secret Manager | No secrets listed |
| CatVox custom service accounts | None listed |
| Workload Identity Federation pools | None listed |
| App Check debug tokens | `{}` for the preserved Firebase iOS app |
| Firestore `usage` collection | Empty |

Post-cleanup manual regression: a fresh Xcode build/deploy and iPhone scan was
run successfully against active Dev. `kathelix-catvox-dev` request logs showed
multiple successful `getSignedUploadURL` and `analyseVideo` HTTP 200 pairs,
including `getSignedUploadURL` at `2026-05-16T11:56:52Z` and `analyseVideo` at
`2026-05-16T11:56:54Z`.

## Intentionally Preserved

| Resource | Reason |
|---|---|
| GCP/Firebase project `kathelix-catvox-prod` | Keeps the desired future production project ID available and avoids project-ID deletion/recreation uncertainty |
| Firebase iOS app `1:953500951129:ios:1595a4c27cd8f3f7964748` / `com.kathelix.catvox` | It matches the future App Store bundle ID. The future Prod slice should either import this app into Terraform state or explicitly delete/recreate it after confirming Firebase app recreation behavior. |
| Firestore database container `(default)` in `nam5` | Kept to avoid Firestore soft-delete/recreate delays; CatVox Dev data was removed from the `usage` collection group. The future Prod slice should import or intentionally recreate this database. |
| Default Google/Firebase service accounts | Platform-managed accounts, not CatVox custom service accounts |
