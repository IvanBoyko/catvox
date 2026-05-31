# Technical Requirements Document: CatVox AI (MVP)

**Version:** 3.1
**Company:** Kathelix Ltd  
**Project Lead:** Ivan Boyko
**Date:** 12 May 2026
**Status:** Infrastructure & Backend Definition

---

## 1. Executive Summary
CatVox AI is a premium, minimalist iOS application designed to interpret cat behavior from short video clips using multimodal Generative AI (Gemini 2.5 Flash). The app serves as a high-tech brand ambassador for Kathelix Ltd, showcasing expertise in AI integration, Cloud architecture, and superior UX design.

For MVP, the user can either record a new video in-app or select an existing video from Photos, provided the submitted clip satisfies the product limits and validation rules defined in this document.

---

## 2. Brand Identity & Design Language
* **Brand Pillars:** Resilience (Phoenix narrative), Engineering Excellence, Playful Intelligence.
* **Visual Style:** Glassmorphism (Frosted glass), dark mode aesthetics, fluid spring-based animations.
* **Brand Palette:** Primary gradient Indigo `#4F46E5` → Cyan `#06B6D4`. Used for progress rings, primary CTAs, and interactive controls.
* **App Icon:** 1024 × 1024 px master asset. All platform-required scaled variants must be derived from this master.
* **Target Market:** UK & International English-speaking tech-savvy pet owners.

---

## 3. Functional Requirements

### 3.1 Core Features (MVP)
* **Unified Scan Entry:** The home screen exposes one primary CTA labeled **Read My Cat**. After tapping it, the app presents a source choice sheet with:
    * **Record New Video**
    * **Choose from Photos**
* **Video Capture:** In-app recording supports clips up to **10 seconds**. The user may stop recording early once a minimum capture threshold of **2.0 seconds** has elapsed. If the user does not stop manually, recording ends automatically at 10 seconds, with an audio ping at the moment recording ends.
* **Post-Capture Review:** After an in-app recording ends, the app presents a lightweight review decision with:
    * **Retake**
    * **Use This Clip**
  Upload and analysis begin only after the user chooses **Use This Clip**.
* **Photos Import:** The app supports selecting an existing video from the user's Photos library using the system video picker flow. The picker is restricted to videos, but detailed eligibility checks are performed by the app after selection rather than by a custom filtered gallery browser.
* **Video Validation Rules:** Before upload, the app must validate the candidate video locally. MVP acceptance rules are:
    * maximum duration: **10 seconds**
    * maximum file size: **100 MB**
    * supported inputs: native **HEVC (.mov)**, H.264, and common iPhone-exported video variants
    * unsupported input: **ProRes**
    * no in-app trimming in MVP
    * no client-side transcoding or re-encoding in MVP
* **Video Pipeline:** In-app recording uses native **HEVC (.mov)** with resolution hard-capped at **1920 × 1080 (1080p)**. The cap keeps free-tier clip sizes to approximately 15–25 MB per 10-second recording. Devices that do not support HEVC fall back silently to H.264. For Photos-imported videos, MVP accepts videos that pass the validation rules above, including temporary acceptance of 4K source video for simplicity. Re-evaluation of 4K cost and normalization strategy is deferred.
* **Multimodal Analysis:** Simultaneous processing of video (body language) and audio (vocalization) via Vertex AI.
* **Persona Engine:** Logic to assign one of 6 "Cat Personas" to the interpretation to drive engagement and humor.
* **Scan History:** The app saves a local history of successful scans using on-device persistent storage. Each saved scan is a self-contained record consisting of:
    * the original clip preserved in CatVox app-local storage
    * the structured AI result returned by the backend
    * a locally generated thumbnail for list presentation
    * source metadata and timestamps
* **History Save Rule:** A scan is persisted only after analysis completes successfully and a valid result payload is returned. Failed validation attempts, rejected selections, upload failures, quota rejections, retakes, and abandoned flows must not create history entries.
* **History Reliability:** For MVP, CatVox must preserve its own app-local copy of the original clip for each successful scan, including clips imported from Photos. This keeps history self-contained and reliable even if the user later deletes the original Photos asset.
* **History Replay:** Opening a saved scan from history must use the locally persisted clip and AI result. It must not trigger a new upload, a new backend analysis request, or quota consumption.
* **Result Completion Flow:** Successful scans are already persisted before the user leaves the Result screen. The Result screen action is therefore a completion/exit action rather than the persistence trigger.
* **Shareable Result Video:** From a completed result, the user may generate a separate rendered video derived from the preserved local clip and saved AI result. The original clip must remain untouched. See ADR-0009.
* **On-Demand Rendering Rule:** CatVox must render shareable videos only when the user explicitly taps a save/share action. The app must not auto-render derived videos after every scan.
* **Overlay Content:** The rendered overlay must include:
    * the saved `cat_thought` as the primary visual overlay
    * the saved persona label
    * the saved primary emotion label
    * subtle CatVox / Kathelix branding
* **MVP Export Style:** The first share export style should be a single CatVox-owned template rendered on top of the original clip. In MVP, that template should keep the `cat_thought` as the dominant bottom card, present persona and primary emotion in a compact secondary metadata card, and use subtle CatVox / Kathelix branding rather than loud decorative framing. Multiple style packs are out of scope for MVP.
* **Aspect Ratio Rule:** MVP share exports must preserve the original input clip aspect ratio rather than reframing into a fixed social aspect ratio. This keeps export behavior predictable and avoids crop / letterbox decisions in the first release. See ADR-0009.
* **Adaptive Overlay Scaling Rule:** Share-overlay layout and typography must scale from the actual rendered frame and available card geometry rather than from fixed absolute caps, so the exported style stays proportionate across portrait, landscape, square, HD, and 4K clips.
* **Preview Rule:** MVP does not require a separate rendered-video preview screen before save/share. The user triggers rendering directly from the Result screen and then proceeds to save or share the derived output.
* **Share Destinations:** The app must support both:
    * saving the rendered output to Photos
    * opening the system share sheet for the rendered output
* **Export Failure Handling:** If rendering or export fails, the app must show a minimal user-facing error and log internal diagnostics for developer investigation.

### 3.2 Monetization & Sustainability
* **Credit System:** 5 free scans/day to manage GCP costs.
* **Quota Burn Rule:** The backend reserves a quota slot in Firestore after uploaded-object validation succeeds and before invoking Vertex AI. The reservation is converted into a consumed quota unit only when analysis completes successfully and a valid result payload is returned. Failed local validation attempts, rejected selections, abandoned uploads, and analysis failures before a valid result payload do not consume quota. Abandoned in-flight reservations expire automatically. See ADR-0015.
* **Quota Error Contract:** When the daily scan quota is exhausted, backend entry points must return HTTP `429` with `Retry-After` set to the number of seconds until the next UTC quota reset, and a JSON body with `code: "daily_scan_quota_exceeded"`, a user-readable `message`, `limit: 5`, `remaining: 0`, and `resetAt` as an ISO-8601 UTC timestamp. The iOS client must treat only this machine-readable code as the quota-exceeded state; other `429` causes must fall through to normal failure handling.
* **Pro Tier (IAP):** One-time in-app purchase for unlimited scans and watermark removal.
* **Brand Promotion:** Subtle "Powered by Kathelix" watermark on all free-tier exports.
* **MVP Watermark Rule:** Until StoreKit 2 Pro entitlement logic exists, CatVox should treat exported share videos as free-tier exports and burn in subtle CatVox / Kathelix branding by default.

---

## 4. AI System Instructions (The "Prompt Gate")

### 4.1 Role & Context
Short version:
You are CatVox AI, a multimodal expert in feline ethology and a sophisticated creative writer. Your task is to analyze short video clips (including audio) to provide professional insights into a cat's emotional state, paired with a witty "inner monologue" translation.

Full prompt: `docs/systemInstruction.md` — this is the single source of truth for the system instruction. The Cloud Function build script copies it into the deployment artifact at build time; editing the file and merging the PR is all that is required to update the live prompt. The machine-enforced JSON output schema is defined separately in `functions/src/gemini.ts` via the Google Gen AI SDK `responseSchema` for Gemini on Vertex AI; the prompt should describe behavior, not duplicate the literal schema. (See ADR-0008, ADR-0010, and ADR-0012.)

### 4.2 The 6 Cat Personas
Select the archetype that best fits the observed behavior:
1. **The Grumpy Boss:** Authoritative, judgmental, and demanding.
2. **The Existential Philosopher:** Poetic, melancholic, and confused by the "red dot."
3. **The Dramatic Diva:** High-octane energy; grand theatrical flair.
4. **The Secret Agent:** Stealthy, tactical; treating the room as a mission zone.
5. **The Chaotic Hunter:** Pure prey-drive energy; "zero thoughts" behind the eyes.
6. **The Affectionate Sweetheart:** Detached, calm, and observing with silent peace.

### 4.3 API Data Schema
The backend must return ONLY a valid JSON object following this structure:
{
  "primary_emotion": "string",
  "confidence_score": float (0.00 - 1.00),
  "analysis": "2-3 sentences of expert feline behavior analysis",
  "persona_type": "string",
  "cat_thought": "First-person monologue matching the assigned persona",
  "owner_tip": "A practical, actionable suggestion for the owner"
}

This structure is the human-readable contract. The runtime-enforced schema lives
in `functions/src/gemini.ts` as a Google Gen AI SDK `responseSchema`, with all six fields
required. `confidence_score` should preserve meaningful fractional precision
(for example `0.99`, not only `0.9`) because the app may render the value as a
percentage. See ADR-0010 and ADR-0012.

---

## 5. UI/UX Specifications

### 5.1 Key Screens
1. **Home Screen:** Minimalist dashboard with this top-to-bottom order:
    * the app icon itself and `Powered by Kathelix` text
    * a browsable list of previous scans
    * one primary CTA labeled **Read My Cat** and supporting quota text such as `5 free scans remaining today`
2. **Source Choice Sheet:** A lightweight chooser offering:
    * **Record New Video**
    * **Choose from Photos**
3. **Recording Screen:** Viewfinder with a progress ring for a clip up to 10 seconds, a tappable stop control after the minimum threshold is reached, and a lightweight post-capture review step.
4. **Post-Capture Review State:**
    * shown immediately after recording ends, whether by early stop or automatic 10-second completion
    * offers:
        * **Retake**
        * **Use This Clip**
5. **Result Screen:**
    * The original scanned clip remains the visual foundation of the screen during upload, completed result display, and reopened saved-scan playback.
    * Background playback is muted and continuous.
    * The clip must preserve its full original frame using a fitted presentation rather than stretch or crop-to-fill treatment.
    * When the clip aspect ratio does not fill the display, the surrounding space should use a soft ambient treatment derived from the same clip so the presentation feels intentional and premium rather than like plain dead padding.
    * The same fitted local clip presentation is used when reopening a saved scan from history.
    * Animated Glassmorphism "Thought Bubble".
    * **Confidence Score UI:** The percentage ring must be dynamically color-coded:
        * **Green:** > 80% (High Confidence)
        * **Amber:** 50% - 80% (Moderate Confidence)
        * **Red:** < 50% (Low Confidence/Ambiguous)
    * Expandable "Expert Insights" drawer.
    * On-demand actions to:
        * generate and save the rendered share video to Photos
        * generate and open the system share sheet for the rendered share video
    * MVP does not require a separate preview step before those actions.
    * "Done" CTA.
6. **Scan History List:**
    * Presents saved scans in chronological order, with the newest saved scan closest to the bottom of the list.
    * Each row corresponds to one saved scan.
    * Each row shows:
        * a thumbnail image for the saved clip
        * a mood and/or persona label
        * the beginning of the saved `cat_thought` text
    * Tapping a row opens the saved result for that scan.

### 5.2 Validation UX
* If a Photos-selected video fails validation, the app must reject it before upload and clearly explain the reason.
* Rejection messaging must be specific and user-readable, using these canonical messages:
    * "This video is longer than 10 seconds. Please choose a shorter clip."
    * "This video is larger than 100 MB. Please choose a smaller clip."
    * "ProRes videos aren't supported."
    * "This video format isn't supported."
* The MVP UX favors clear post-selection validation messaging over a custom gallery browser with disabled or hidden ineligible assets.

### 5.3 Recording UX
* The record control starts capture when tapped from idle state.
* During recording, the central capture control must become the stop affordance once the minimum capture threshold is reached.
* Minimum early-stop threshold: **2.0 seconds**.
* Before 2.0 seconds, tapping the control must not end recording.
* If the user taps the control before 2.0 seconds, the app should show a brief hint such as `KEEP RECORDING A BIT LONGER`.
* The UI must make the early-stop affordance clear while recording, using explicit helper text such as:
    * before early-stop is allowed: `KEEP RECORDING`
    * after early-stop is allowed: `TAP TO FINISH`
* When recording ends, the app must not begin upload or analysis immediately.
* Upload and analysis begin only after the user taps **Use This Clip**.
* Tapping **Retake** discards the recorded clip and returns the user to the live camera view in ready-to-record state.
* The same post-capture review flow applies whether recording ended by manual early stop or by automatic completion at 10 seconds.

### 5.4 Scan History UX
* Scan history is part of the Home experience and should be easy to browse without entering a separate management flow.
* The history list must use chronological ordering so earlier scans appear higher in the list and the newest saved scan sits nearest to the primary CTA at the bottom of Home.
* If there is no saved scan history yet, the Home screen should show a lightweight empty state indicating that completed scans will appear there.
* Each history row must remain lightweight and scannable, prioritizing thumbnail, interpretation cue, and short text preview over dense metadata.
* The `Done` action on the Result screen must return the user to the Home screen.
* After the user returns from a successful result, the newly persisted scan must be visible in the scan history list in its chronological position.
* Deleting a saved scan must always require user confirmation.
* Confirmed deletion must remove:
    * the persisted history record
    * the CatVox-owned local original clip
    * any other CatVox-owned local assets associated with that scan
* Deleting a saved scan must never delete the user's original Photos asset.

### 5.5 Share Export UX
* Share export actions live on the Result screen so the user can act from either a newly completed scan or a reopened saved scan.
* The app must not block normal result viewing on initial load by eagerly rendering a share export in the background.
* When the user taps a share-export action, the app should show lightweight in-context progress while rendering is underway.
* The Result screen must not allow `Done` dismissal while share rendering or save-to-Photos work is in progress.
* The share overlay should keep the `cat_thought` visually dominant over the persona and emotion labels.
* The MVP share template should feel visually aligned with the in-app result UI: soft glass surfaces, restrained borders, subtle branding, and no heavy badge framing around secondary metadata.
* Branding should be present but subtle rather than overpowering the clip content or thought overlay.
* If saving to Photos succeeds, the app should confirm success with a lightweight user-facing confirmation.

---

## 6. Cloud Infrastructure & Security (IaC)

### 6.1 Infrastructure as Code (Terraform)
* **Provider:** Google Cloud Platform (GCP).
* **GCP/Firebase Projects:** Dev runs in project ID `kathelix-catvox-dev`. Region is `us-central1`; Firestore location is `nam5` (US multi-region). `kathelix-catvox-prod` is the Prod environment project (being provisioned) and must not be deleted; pre-split Dev leftovers were cleaned on 2026-05-16. Each environment's identity lives in `config/environments/<env>.xcconfig`. See ADR-0017, ADR-0018, and `docs/archive/LEGACY_PRESPLIT_CLEANUP_REPORT_2026-05-16.md`.
* **Terraform State:** Remote state is stored in a per-environment GCS bucket (`us-central1`, object versioning enabled) and is never stored locally or committed to source control. Active Dev uses `gs://catvox-tf-state-kathelix-catvox-dev/catvox/state`. The `Makefile` dynamically injects the backend configuration inline via `-backend-config` flags during `terraform init`, pulling bucket coordinates from the current environment's `xcconfig` file.
* **Resource Scope:**
    * **Project Services:** Enablement of `aiplatform`, `cloudfunctions`, `cloudbuild`, `run`, `eventarc`, `pubsub`, `firestore`, `storage`, `secretmanager`, `artifactregistry`, `firebase`, `firebaseextensions`, `firebaseappcheck`, `compute`, `monitoring`, `clouderrorreporting`, and `iam`.
    * **Databases:** Explicit provisioning of a **Firestore instance** in `(default)` mode.
    * **Artifact Registry repository** for Cloud Functions (2nd Gen) build images.
    * **Service Accounts:** `catvox-backend-sa` (Cloud Functions runtime) and `catvox-ci-sa` (Terraform CI / GitHub Actions) — see §6.3 for roles.
    * **Runtime configuration and secrets:** committed environment config for non-secret runtime identifiers and Secret Manager for the Dev-only `APP_CHECK_DEBUG_TOKEN` credential.

### 6.2 Compute & API Orchestration
* **Environment:** Firebase Cloud Functions (2nd Generation).
* **Runtime:** Node.js 22 (TypeScript).
* **Vertex AI Integration:** Call Gemini 2.5 Flash through the Google Gen AI SDK configured for Vertex AI (`vertexai: true`), using `fileData` (GCS URI) for multimodal analysis. See ADR-0012.

### 6.3 Security & Identity
* **App Verification:** Firebase App Check mandatory for all backend entry points. App Attest is the production provider for Apple platforms; Debug Provider is used for local development. (See ADR-0002.)
* **Debug App Check Token Persistence:** Debug iPhone builds persist a registered App Check debug token in local app `UserDefaults` after launch with `AppCheckDebugToken` or `FIRAAppCheckDebugToken`. Later Debug launches from the app icon restore that token into the process environment before Firebase App Check initializes, so token refreshes do not fall back to an unregistered generated token. If Firebase rejects the restored token, CatVox clears the stored Debug token and reports an app verification failure instead of surfacing Firebase's raw token-exchange response. This bootstrap is compiled out of Release builds; production App Check remains App Attest-only. `make ios-device-launch` passes the registered debug token from local environment variables or the selected ignored `terraform/env/<environment>.tfvars` without printing it. (See ADR-0016.)
* **Secrets:** No credentials or private operator values are committed. Runtime project identity is non-secret environment configuration; true secrets remain in Secret Manager or per-environment GitHub Environment secrets.
* **Service Account: `catvox-backend-sa`** — Runtime identity for Cloud Functions. Holds only the minimal roles required at runtime; never has CI-level access.
    * `roles/aiplatform.user` — invoke Gemini 2.5 Flash via Vertex AI.
    * `roles/storage.objectViewer` — read video objects from GCS for Vertex AI.
    * `roles/storage.objectCreator` — create objects in GCS; required so that signed URLs generated by this SA (via `signBlob`) are honoured by GCS when the iOS client PUTs the video file.
    * `roles/datastore.user` — read/write Firestore usage documents.
    * `roles/secretmanager.secretAccessor` — reserved for runtime secrets if later adopted; current project identity is not stored as a Secret Manager secret.
    * `roles/iam.serviceAccountTokenCreator` (self) — generate signed GCS upload URLs for the iOS client.
* **Service Account: `catvox-ci-sa`** — Terraform CI identity for GitHub Actions. Holds broader project-level rights needed for IaC; isolated from the runtime SA to limit blast radius if either is compromised. (See ADR-0006.)
    * `roles/editor` — manage GCP resources (APIs, GCS, Artifact Registry, Secret Manager, Firestore, service accounts).
    * `roles/resourcemanager.projectIamAdmin` — read and write project-level IAM bindings.
    * `roles/iam.serviceAccountAdmin` — set IAM policies on individual service accounts (`google_service_account_iam_member` resources); intentionally excluded from `roles/editor`.
    * `roles/secretmanager.secretAccessor` — read secret versions during `terraform plan/apply`; intentionally excluded from `roles/editor`.
    * `roles/storage.objectAdmin` (state bucket only) — read/write Terraform state. Managed by Terraform (`google_storage_bucket_iam_member.ci_sa_state_bucket_admin`); the bucket itself is outside IaC scope.

### 6.4 Data Lifecycle & Persistence
* **Google Cloud Storage (GCS):**
    * Bucket: `catvox-raw-videos-<project-id>` (project ID suffix ensures global uniqueness).
    * **CORS Policy:** Configuration to allow direct uploads from the iOS app.
    * **Lifecycle Rule:** `action: Delete`, `condition: Age > 1 day`.
    * **Vertex AI service agent** (`service-{PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com`) requires `roles/storage.objectViewer` on this bucket so that Vertex AI can fetch the video via the `fileData` GCS URI. This binding is managed by Terraform (`google_storage_bucket_iam_member.vertexai_sa_raw_videos_viewer`).
* **Firestore (Usage Guard):**
    * Collection: `usage/{userId}`.
    * Schema: `{ count: integer, lastResetDate: string (YYYY-MM-DD), reservations: map }`.
    * Reservation map shape:
      ```ts
      reservations: {
        [analysisRequestId: string]: {
          gcsUriHash: string,
          createdAt: Timestamp,
          expiresAt: Timestamp
        }
      }
      ```
    * **Logic:** Backend checks `count + activeReservations` against the daily limit. `analyseVideo` creates an atomic Firestore reservation after cheap uploaded-object validation and before invoking Vertex AI, then converts that reservation into an incremented `count` after a valid analysis result is produced. Expired reservations are pruned opportunistically during quota checks and reservation transactions. Requests rejected by quota use the quota error contract (HTTP `429`, `code: "daily_scan_quota_exceeded"`). See ADR-0015.
* **userId:** A UUID generated once on first launch and persisted in `UserDefaults` under the key `"catvox.userId"`. Sent by the iOS client with every `analyseVideo` request and reused as the anonymous PostHog analytics identity. Forward-compatible with Firebase Auth — when Auth is introduced, the shared client identity value is replaced with the authenticated UID and the Firestore schema requires no changes. (See ADR-0007 and ADR-0011.)
* **App-Local Scan Persistence:**
    * Local scan history is stored on-device using SwiftData for metadata persistence.
    * Each persisted scan record must include at least:
        * a stable local identifier
        * the local file location of the CatVox-owned original clip
        * the saved AI result fields
        * source type metadata (`recorded` or `photos`)
        * thumbnail reference
        * created-at timestamp
    * Original clip files are stored in CatVox-controlled app-local storage and referenced by the persisted scan record.
    * Thumbnail images are generated locally and stored for fast history rendering.
    * Persisted scan history must remain available offline.
    * Removing a saved scan must delete the SwiftData record together with CatVox-owned local files for that scan.
    * CatVox must never attempt to delete the user's original Photos-library asset.
* **Rendered Share Output Lifecycle:**
    * Rendered share videos are temporary derived artifacts, not part of the durable scan-history record.
    * Rendered outputs should be stored in CatVox-owned cache or temporary storage, outside the canonical original-clip location.
    * The app should opportunistically clean up old rendered outputs and must delete render-cache artifacts associated with a scan when that scan is deleted.
    * MVP does not require permanent retention, indexing, or browsing of all previously rendered share files.

### 6.5 Validation & Upload Guardrails
* **Client Validation:** The iOS client must validate duration, size, and basic format eligibility before requesting a signed upload URL whenever that metadata is available locally.
* **Backend Validation Point:** The backend must validate uploaded object constraints in the analysis path before invoking Vertex AI.
* **Backend Validation Rules:** For MVP, backend validation should enforce upload file-size guardrails before invoking Vertex AI:
    * file size <= 100 MB
* Duration <= 10 seconds remains a client-side MVP rule for now; backend duration enforcement is deferred and tracked in backlog.
* **Upload Economics:** Signed upload URLs should not be issued for videos that the client already knows are invalid. This is primarily a cost-control and UX measure, not a trust substitute.
* **Optional Abuse Mitigation:** A lightweight rate-limit on signed URL issuance is desirable if it can be implemented cheaply without materially complicating MVP delivery; otherwise it should be deferred to post-MVP work.

### 6.6 Product Analytics
* **Provider:** PostHog iOS SDK, added through `project.yml` so the dependency survives XcodeGen regeneration. (See ADR-0011.)
* **Environment Isolation:** Dev and Prod analytics must use separate PostHog projects, mapped 1:1 to CatVox environments (Debug iOS + Dev GCP + Dev PostHog, Release iOS + Prod GCP + Prod PostHog). The existing `CatVox Dev` project remains Dev; a dedicated `CatVox Prod` project is required before real production analytics are enabled. The `app_environment` property must still be attached to every event as defense-in-depth metadata, but it is not the primary Dev/Prod isolation mechanism. See ADR-0019 and ADR-0020.
* **Configuration:** The app reads the environment-specific PostHog project token and host from CatVox-prefixed `Info.plist` values generated by XcodeGen build settings, with `CATVOX_POSTHOG_PROJECT_TOKEN` and `CATVOX_POSTHOG_HOST` environment variables as local overrides. Missing token configuration must disable analytics gracefully rather than crashing the app. Analytics must also be disabled during XCTest and SwiftUI preview runtimes so CI and previews do not pollute analytics dashboards.
* **SDK Scope:** The app uses explicit CatVox-owned event capture only. PostHog automatic lifecycle capture, automatic screen-view capture, element interaction autocapture, rage-click capture, surveys, session replay, feature-flag preloading, and automatic default person properties must stay disabled unless a later TRD update explicitly adopts those features.
* **Identity:** PostHog identifies the user with the same anonymous per-install UUID stored under `"catvox.userId"` for quota enforcement. No authenticated user account is required for MVP analytics.
* **Privacy Boundary:** Analytics events must not include raw video, local file paths, Photos asset identifiers, AI-generated cat thoughts, or owner-entered content. Event properties should stay limited to product metadata such as source type, validation failure reason, persona label, confidence score, quota trigger, share action, and non-content error categories.
* **Required MVP Events:**
    * `scan_source_chosen` with `source`
    * `photos_picker_opened`
    * `photos_picker_cancelled`
    * `photos_clip_selected`
    * `video_validation_passed` with `source_type`
    * `video_validation_failed` with `source_type` and `validation_failure_reason`
    * `recording_started`
    * `recording_finished`
    * `recording_retake_tapped`
    * `recording_cancelled`
    * `recording_completed`
    * `analysis_completed` with persona/emotion/confidence/source metadata
    * `analysis_failed`
    * `analysis_retry_tapped`
    * `quota_exceeded`
    * `quota_card_shown`
    * `share_export_started`
    * `share_export_render_failed`
    * `share_sheet_opened`
    * `scan_shared`
    * `share_sheet_cancelled`
    * `scan_saved_to_photos`
    * `photos_permission_denied`
    * `share_save_failed`
    * `scan_deleted`
    * `upgrade_to_pro_tapped`

### 6.7 Named Environment Configuration
CatVox uses named environments. Initial names are `dev` and `prod`, but product code, scripts, CI, and Terraform conventions must treat the environment name as data so future environments can be added without source-level branching. See ADR-0017.

Each environment owns its own GCP/Firebase project, Firebase iOS app, App Check configuration, backend endpoints, PostHog project/token configuration, GitHub Environment secret set, and Terraform state. PostHog Terraform automation lives in the `terraform/posthog/` root with state under prefix `posthog/state` in the matching environment's GCS bucket; operational PostHog API credentials live in per-environment GitHub Environment secrets (`POSTHOG_API_KEY`), while the PostHog API host, project ID, and organization ID remain in `config/environments/<environment>.xcconfig` as `CATVOX_POSTHOG_API_HOST_NAME`, `CATVOX_POSTHOG_PROJECT_ID`, and `CATVOX_POSTHOG_ORGANIZATION_ID` so app config is the source of truth. `make posthog-environment-provision` configures/verifies the matching GitHub Environment, stores `POSTHOG_API_KEY`, applies the PostHog root, and writes the public project ID/token back to xcconfig. See ADR-0020.

Active Dev defaults point at `kathelix-catvox-dev`. Committed `config/environments/<environment>.xcconfig` files are the source of truth for non-secret app, backend, CI-auth identity, analytics, and Terraform environment values so bare Xcode runs and Makefile-driven automation read the same values. XcodeGen attaches the selected xcconfig to the app target and passes values through build settings into `Info.plist`; URL values in xcconfig are stored as hostnames and composed into `https://` URLs at the Info.plist and Makefile boundaries. The Makefile derives the matching `CATVOX_ENV_CONFIG` and Terraform tfvars basename from `CATVOX_ENVIRONMENT` by default, and Terraform targets reject tfvars basenames that do not match `CATVOX_ENVIRONMENT`. GitHub Environment secrets and ignored `terraform/env/<environment>.tfvars` files hold only true secrets or deliberately private values: `POSTHOG_API_KEY`, App Check debug tokens, and `alert_email`. See ADR-0021 and ADR-0022.

GCP/Firebase foundation values sourced from xcconfig include:
* `CATVOX_PROJECT_ID`
* `CATVOX_GCP_CI_SERVICE_ACCOUNT` and `CATVOX_GCP_WIF_PROVIDER` as full strings
* `CATVOX_FUNCTION_REGION`, `CATVOX_FIRESTORE_LOCATION`, and `CATVOX_TF_STATE_BUCKET`
* `CATVOX_IOS_BUNDLE_ID`
* `CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME`, `CATVOX_FIREBASE_IOS_APP_DELETION_POLICY`, and `CATVOX_FIREBASE_APPLE_TEAM_ID`
* `CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM` — boolean toggle for environment provisioning.

Committed boolean environment values use lowercase `true` or `false` only.
Do not use numeric or yes/no forms.

Initial iOS bundle ID convention:
* `com.kathelix.catvox.dev` for Dev/internal builds
* `com.kathelix.catvox` for future App Store Prod

Any environment bundle ID that needs physical-device builds or App Attest must
exist as an explicit Apple Developer App ID under team `QYT76L5836`, with a
development provisioning profile for local device proof. Local Xcode account
configuration is workstation setup, not a per-environment cloud artifact.

Cloud Functions runtime settings:
* Each environment derives the same runtime service-account name, `catvox-backend-sa`, inside that environment's own GCP project. The resulting IAM principals are therefore distinct per environment, for example `catvox-backend-sa@<project-id>.iam.gserviceaccount.com`.
* Function region defaults to `us-central1`; `CATVOX_FUNCTION_REGION` overrides the Cloud Functions region, and `CATVOX_VERTEX_LOCATION` can separately override the Vertex AI location when a future environment needs different model locality.

Firebase plist convention:
* `CatVox/Resources/Firebase/GoogleService-Info-<environment>.plist`
* The app loads the plist matching `CATVOX_ENVIRONMENT`.
* `make ios-validate-env-config` and the app target pre-build script validate that the selected plist matches the selected environment project ID, Firebase app ID, API key, and bundle ID.
* Until the real Prod plist lands, CI must still run structural Prod config validation against `config/environments/prod.xcconfig`. That structural check may allow only the explicitly deferred Step 3 values for Firebase app ID, Firebase API key, and backend endpoint hosts.

Mutable live integration tests may run only against environments explicitly marked integration-safe with `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`. Protected environments get non-invasive smoke tests only through `CATVOX_ENVIRONMENT=<env> make smoke` and `docs/SMOKE_CHECKLIST.md`.

---

## 7. CI/CD Pipelines

### 7.0 Shared Local / CI Command Facade
CatVox uses the repository-root `Makefile` as a thin facade for common developer and CI command bodies. Developers should prefer discoverable `make` targets such as `make ios-test`, `make functions-deploy`, `make functions-integration`, `make terraform-plan`, and `make terraform-apply CONFIRM=apply` over manually retyping long command sequences.

GitHub Actions may call Makefile targets for the command body, but workflow YAML remains responsible for CI-only concerns such as checkout, toolchain installation, dependency caching, Workload Identity Federation authentication, path/event triggers, and PR comments. See ADR-0014.

### 7.0.1 Markdown Documentation Pipeline
* **Trigger:** Pushes and pull requests targeting `main` when files under `docs/`, the top-level `README.md`, `.markdownlint.jsonc`, or the workflow file itself change. Manual `workflow_dispatch` runs are also supported.
* **Runner:** Ubuntu latest.
* **Steps:** Checkout → markdownlint over `README.md` and `docs/**/*.md` using the repository `.markdownlint.jsonc` config.
* **Purpose:** Provides a cheap documentation-quality check for docs-heavy changes without waking the macOS iOS build workflow.

### 7.1 iOS Build Pipeline
* **Trigger:** Pushes and pull requests targeting `main` when iOS-relevant source, project, config, scripts, Makefile, or workflow files change. Manual `workflow_dispatch` runs always execute the iOS build path.
* **Runner:** macOS 15 (Xcode 16, iOS 17+ SDK).
* **Steps:** Checkout → install XcodeGen / `xcpretty` → `make ios-generate` → validate Dev Firebase config → structurally validate Prod config → `make ios-build-only` for the generic iOS Simulator slice (`CODE_SIGNING_ALLOWED=NO`) → `make ios-test-only` on a concrete simulator device (`platform=iOS Simulator,name=iPhone 16,OS=latest`). Xcode cannot run tests on `generic/platform=iOS Simulator`.
* **Purpose:** Catches build breaks, XcodeGen drift, and unit-test regressions on iOS-relevant changes without spending macOS CI time on docs-only edits. No device signing or provisioning profiles required.

### 7.1.1 iOS UI Test Pipeline
* **Local command:** `make ios-ui-test` regenerates the Xcode project and runs the dedicated `CatVoxUITests` XCUITest scheme on a concrete iPhone simulator destination (`IOS_UI_TEST_DESTINATION`, defaulting to `platform=iOS Simulator,name=iPhone 16,OS=latest`).
* **CI trigger:** The Build workflow runs UI tests as a separate job on iOS-relevant pushes to `main` and on manual `workflow_dispatch`, after the normal build/unit-test job passes. Pull requests keep running the cheaper build and unit-test path unless UI coverage is manually requested after merge.
* **Launch mode:** UI tests launch the app with `-uiTesting` and `-mockBackend`; individual scenarios may also use `-seedHistory` or `-forceQuotaExceeded`.
* **State model:** `-uiTesting` disables analytics, resets test-local quota/user/history state, and uses an in-memory SwiftData store. `-seedHistory` inserts deterministic local saved-scan data and app-owned placeholder files so history replay opens Result without upload or analysis. `-forceQuotaExceeded` renders the quota/upgrade UI from local state without backend calls.
* **Coverage boundary:** The baseline suite covers Home launch smoke, source-choice visibility/dismissal, seeded history replay, and mocked quota exceeded UI. It intentionally does not use real camera, Photos picker content, Firebase App Check, GCS, Gemini/Vertex AI, user accounts, network calls, snapshots, Appium, Maestro, BrowserStack, or Firebase Test Lab.
* **Extension path:** The suite remains native XCUITest and launch-argument driven so it can later run on real devices through Firebase Test Lab or BrowserStack without changing app behavior or adopting a second UI automation framework. See `docs/UI_TESTING.md`.

### 7.2 Terraform Infrastructure Pipeline
* **Trigger:** Push or pull request targeting `main` when files under `terraform/`, the repository `Makefile`, or the workflow file itself change.
* **Authentication:** Keyless via **Workload Identity Federation (WIF)**. GitHub Actions presents its OIDC token; GCP exchanges it for a short-lived credential scoped to `catvox-ci-sa` (the dedicated Terraform CI identity). No long-lived service account keys are stored anywhere.
* **Plan job (on PR):**
    1. Authenticate to GCP via WIF.
    2. `make terraform-fmt-check` → `make terraform-init` → `make terraform-validate` → `make terraform-ci-plan`.
    3. Post a structured comment to the PR with fmt/init outcomes and the full plan output (collapsible, truncated at 60k characters if needed).
    4. Fail the job if the plan step fails, surfacing the error in the PR comment.
* **Apply job (on merge to `main`):** `make terraform-init` → `make terraform-ci-apply` (`terraform apply -auto-approve -no-color`).
* **Variables:** The workflow reads `config/environments/<environment>.xcconfig` before WIF authentication, then the Makefile passes non-secret GCP/Firebase foundation values to Terraform as `TF_VAR_*` values. Environment-scoped GitHub secrets supply only `TF_VAR_app_check_debug_token` and `TF_VAR_alert_email`. Local ignored `terraform/env/<environment>.tfvars` files should contain only `app_check_debug_token` and `alert_email`.
* **Local apply guard:** Developers must run `make terraform-plan` before review, and local `make terraform-apply` refuses to run unless invoked as `make terraform-apply CONFIRM=apply`. The target still uses Terraform's interactive apply prompt.

### 7.3 Firebase Cloud Functions Pipeline
* **Trigger:** Push or pull request targeting `main` when files under `functions/`, `firebase.json`, `docs/systemInstruction.md`, the repository `Makefile`, or the workflow file itself change. `docs/systemInstruction.md` is included because it is copied into the deployment artifact at build time — a prompt-only change must trigger a redeploy. (See ADR-0008 and ADR-0010.)
* **Authentication:** Same WIF setup as the Terraform pipeline. Workflows read the selected xcconfig before authentication and pass `CATVOX_GCP_WIF_PROVIDER` and `CATVOX_GCP_CI_SERVICE_ACCOUNT` to `google-github-actions/auth`.
* **Build job (on PR and push):** `make functions-install` → `make functions-test` (TypeScript compile check plus backend unit tests).
* **Deploy job (on merge to `main`):** Runs after build passes → `make functions-deploy` (`npm --prefix functions run build` plus `firebase deploy --only functions`).
* **Integration job (after merge-to-main deploy):** Runs `make functions-integration` against the currently deployed integration-safe Dev environment in `kathelix-catvox-dev`. Integration tests may write temporary Dev data when required and must clean it up. The current suite exchanges the registered App Check debug token for a valid App Check token, verifies that both HTTP Functions reject missing App Check tokens with `401 app_check_unauthorized`, verifies the Firestore quota reservation race contract with temporary `usage/{userId}` data through a direct `@google-cloud/firestore` probe, verifies the machine-readable daily-quota HTTP `429` response and structured Cloud Logging entry, then deletes temporary documents. See ADR-0015, ADR-0017, and ADR-0018.
* **Integration auth boundary:** GitHub Actions WIF produces an external-account Application Default Credentials (ADC) file. Direct data-plane probes in `functions/integration/**` should use Google Cloud client libraries such as `@google-cloud/firestore`, which accept that ADC path. Do not initialize Firebase Admin SDK inside the integration test harness unless it has been explicitly verified under GitHub Actions WIF; Admin ADC loading can reject the CI credentials even when the deployed Cloud Functions runtime uses Firebase Admin correctly.
* **Local Dev integration command:** Developers can run the same backend integration suite against the currently deployed Dev backend with `make functions-integration` or `npm --prefix functions run test:integration`. The Makefile target supplies selected environment values from `CATVOX_ENV_CONFIG`, sets `CATVOX_INTEGRATION_MUTATIONS_ALLOWED=1`, and passes `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS=dev` for the integration-safe Dev environment. It preserves an explicitly supplied `CATVOX_APP_CHECK_DEBUG_TOKEN`; when no App Check token environment variable is present, it silently falls back to `app_check_debug_token` in the selected ignored `terraform/env/<environment>.tfvars` if that file/value exists. Direct `npm --prefix functions run test:integration` runs must provide the required `CATVOX_*` environment values or an integration env file.

### 7.4 CI Bootstrap & GitHub Environment Secrets
One-time repository setup, GitHub Actions availability, GitHub Environment protection, and the WIF trust model are documented in `docs/CI_BOOTSTRAP.md`.

Per-environment cloud setup is documented in `docs/CREATE_NEW_ENVIRONMENT.md`. Each environment gets its own GCP project, `catvox-ci-sa`, WIF pool/provider, Terraform state bucket, committed xcconfig values, and GitHub Environment secrets for values that are actually secret or deliberately private.

Active Dev uses the GitHub Environment named `dev` with:

| Secret | Value |
|---|---|
| `TF_VAR_ALERT_EMAIL` | Dev alert recipient |
| `TF_VAR_APP_CHECK_DEBUG_TOKEN` | Dev App Check debug token |
| `POSTHOG_API_KEY` | Dev PostHog scoped personal API key, normally stored by `make posthog-environment-provision` |

### 7.5 Environment Creation Runbook

Use `docs/CREATE_NEW_ENVIRONMENT.md` and `make environment-create` when creating a new GCP/Firebase environment or when reconstructing an environment after a full destroy. The runbook covers project creation, optional billing link, Firebase enablement, Terraform state bootstrap, Functions source bucket bootstrap, Terraform init/plan/apply, Firebase plist export, Functions deploy, GitHub Environment secrets, validation, and legacy pre-split cleanup.

---

## 8. Implementation Backlog (MVP)

The MVP backlog source of truth now lives in `docs/MVP_BACKLOG.md`.

---

## 9. Future Enhancements (Post-MVP)

Future-feature ideas now live in the CatVox Notion Ideas table.
