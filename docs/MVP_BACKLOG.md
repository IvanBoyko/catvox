# MVP Backlog

This file is the source of truth for CatVox MVP backlog status.

## Implementation Backlog (MVP)

* [x] **Asset Integration:** App Icon & Accent Colors implemented.
* [x] **UI Logic:** Confidence Score color-coding implemented.
* [x] **Source Unit Test Baseline:** iOS unit-test target covers backend JSON decoding, persona labels, confidence-tier thresholds, local quota state, saved scan reconstruction, and Photos-import validation messaging; CI runs the iOS test suite.
* [x] **Native UI Test Baseline:** Add a separate XCUITest target and `make ios-ui-test` entrypoint covering Home smoke, source-choice dismissal, seeded history replay, and mocked quota exceeded UI with deterministic launch arguments and no real camera, Photos, backend, or network dependency.
* [x] **GCP Foundation:** Deploy Terraform plan to provision GCS (with CORS), IAM, Artifact Registry, and Firestore.
* [x] **Remote Terraform State:** GCS backend configured and local state migrated; state bucket bootstrapped with versioning enabled.
* [x] **CI/CD Terraform Pipeline:** GitHub Actions workflow live — plan on PR (with PR comment), apply on merge; authenticated via Workload Identity Federation.
* [x] **App Check Repo Wiring:** App Check is wired into the iOS app and backend entry points. App Attest is the production provider, Debug Provider supports local development and integration tests, Debug iPhone builds persist a registered debug token for later app-icon relaunches, and both Cloud Functions verify the `X-Firebase-AppCheck` header using the Firebase Admin SDK before any business logic. `invoker: 'public'` remains intentionally set on `getSignedUploadURL` and `analyseVideo` so anonymous mobile clients can reach the HTTP endpoints at the IAM layer; unauthenticated business access is blocked in-code by App Check validation. (See ADR-0002 and ADR-0016.)
* [x] **App Check Console & Live Gate:** App Attest is enabled for `com.kathelix.catvox` in Apple Developer, the Firebase iOS app is registered with App Attest, the Debug Provider token is registered and available to CI, `make functions-integration` passes with `CATVOX_APP_CHECK_DEBUG_TOKEN`, unauthenticated curl calls to both HTTP Functions return `401 app_check_unauthorized`, and a Debug iPhone scan completed successfully.
* [x] **Backend Proxy:** Firebase Cloud Functions (TypeScript) deployed — `getSignedUploadURL` and `analyseVideo` live in `us-central1`; Firestore usage guard, Vertex AI call, CI deploy pipeline via GitHub Actions.
* [x] **Backend Integration Test Baseline:** TypeScript backend integration suite verifies that both live HTTP Functions reject missing App Check tokens with `401 app_check_unauthorized`, verifies the live Firestore quota reservation race contract against temporary Dev data, and verifies the live Dev backend daily-quota `429` body, `Retry-After`, and structured Cloud Logging event after merge-to-main deploys or local Dev CLI runs. See ADR-0013 and ADR-0015.
* [x] **Video Recording:** Local capture implemented — HEVC codec enforced, resolution hard-capped at 1080p.
* [x] **Video Upload:** Swift upload of the recorded HEVC file to GCS via signed URL; real pipeline live (`mockMode = false`).
* [x] **AI Connection:** Cloud Function calls Vertex AI Gemini 2.5 Flash via the Google Gen AI SDK and `fileData` GCS URI.
* [x] **Quota Exceeded UI:** Dedicated glassmorphic card shown when the daily scan limit is reached (HTTP 429); includes stub "Upgrade to Pro" CTA (shows "Coming soon" alert) and "Maybe Later" dismiss. StoreKit 2 wiring deferred to the Monetization backlog item.
* [x] **Atomic Quota Reservations:** `analyseVideo` reserves quota in Firestore before invoking Vertex AI, converts the reservation into a consumed unit only after a valid result payload, and counts active reservations during quota checks. See ADR-0015.
* [x] **Photos Import:** Add support for selecting an existing video from Photos through the unified scan flow, with local validation for duration, size, and unsupported formats before upload.
* [x] **Early Stop Recording:** Allow users to stop in-app recording after a 2.0-second minimum threshold using the main capture control.
* [x] **Post-Capture Review:** Add `Retake` and `Use This Clip` actions after recording ends; only `Use This Clip` continues to upload and analysis.
* [x] **Backend File Size Validation:** Add backend validation for file size <= 100 MB in the analysis path before Vertex AI is invoked.
* [x] **Scan History Persistence:** Set up SwiftData-backed local storage for successful scans, including saved AI result metadata, thumbnail reference, and CatVox-owned original clip reference.
* [x] **Scan History UI:** Add the frontend history list to the Home experience, showing prior scans with thumbnail, mood/persona cue, and short `cat_thought` preview.
* [x] **Saved Result Reopen:** Allow users to reopen a saved scan from local history without re-upload or re-analysis.
* [x] **Scan Deletion:** Add confirmed deletion of saved scans, removing the history record and CatVox-owned local assets without touching the original Photos asset.
* [x] **Fitted Result Clip Presentation:** Preserve the full original frame on upload, completed result, and reopened history screens, using ambient treatment around unused space instead of crop-to-fill.
* [ ] **Monetization:** Implement StoreKit 2 for "Pro" tier (Unlimited scans).
* [x] **Share Rendering Pipeline:** Add an on-device AVFoundation-based export pipeline that renders a derived share video from the preserved local clip with CatVox overlays.
* [x] **Share Actions:** Add Result-screen actions to save the rendered share video to Photos or open it in the system share sheet.
* [x] **Rendered Output Cleanup:** Store rendered share videos as temporary CatVox-owned artifacts and clean them up with normal cache lifecycle plus scan deletion.
* [x] **Product Analytics:** Add PostHog product analytics for scan source choice, Photos import validation, recording, analysis, quota pressure, sharing/exporting, history deletion, and upgrade intent.
* [x] **Environment Parameterization Baseline:** Document the named-environment model and move current single-environment app/backend/test/deploy values behind generic environment configuration keys without creating new cloud resources.
* [x] **Dedicated Dev Environment:** Provision `kathelix-catvox-dev`, switch active Dev app/runtime/Terraform/GitHub Environment artifacts to it, deploy Functions, validate the Dev Firebase plist selection, and pass Dev backend integration tests. See ADR-0018.
* [x] **Legacy Pre-Split Cleanup:** After a real Debug device scan passed against `kathelix-catvox-dev`, destroyed Terraform-managed Dev leftovers in preserved `kathelix-catvox-prod`, swept non-Terraform leftovers, and recorded a cleanup report before using that project ID for real Prod. See `docs/archive/LEGACY_PRESPLIT_CLEANUP_REPORT_2026-05-16.md`.
* [ ] **Real Production Environment:** Reuse preserved `kathelix-catvox-prod` for the protected production slice with App Store bundle ID, protected GitHub Environment, non-invasive smoke checks only, and no Dev debug tokens or mutable integration settings.
