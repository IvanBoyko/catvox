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
* **Current Deployed Project:** Until the real environment split is complete, GCP/Firebase project ID `kathelix-catvox-prod` is treated operationally as the `dev` environment despite its name. Region remains `us-central1`; Firestore location remains `nam5` (US multi-region). See ADR-0013 and ADR-0017.
* **Terraform State:** Remote state is stored in a GCS bucket (`us-central1`, object versioning enabled) and is never stored locally or committed to source control. The GCS backend enables consistent state access from both local development and CI/CD pipelines. The state bucket is bootstrapped manually (outside of Terraform) to avoid a circular dependency. Future multi-environment state should use explicit backend config files keyed by environment name, for example `terraform/backend/<environment>.hcl`, because Terraform backend blocks cannot use normal input variables.
* **Resource Scope:**
    * **Project Services:** Enablement of `aiplatform`, `cloudfunctions`, `cloudbuild`, `run`, `eventarc`, `pubsub`, `firestore`, `storage`, `secretmanager`, `artifactregistry`, `firebase`, `firebaseappcheck`, and `iam`.
    * **Databases:** Explicit provisioning of a **Firestore instance** in `(default)` mode.
    * **Artifact Registry repository** for Cloud Functions (2nd Gen) build images.
    * **Service Accounts:** `catvox-backend-sa` (Cloud Functions runtime) and `catvox-ci-sa` (Terraform CI / GitHub Actions) — see §6.3 for roles.
    * **Secrets:** Secret Manager for `GCP_PROJECT_ID` and `APP_CHECK_DEBUG_TOKEN`.

### 6.2 Compute & API Orchestration
* **Environment:** Firebase Cloud Functions (2nd Generation).
* **Runtime:** Node.js 22 (TypeScript).
* **Vertex AI Integration:** Call Gemini 2.5 Flash through the Google Gen AI SDK configured for Vertex AI (`vertexai: true`), using `fileData` (GCS URI) for multimodal analysis. See ADR-0012.

### 6.3 Security & Identity
* **App Verification:** Firebase App Check mandatory for all backend entry points. App Attest is the production provider for Apple platforms; Debug Provider is used for local development. (See ADR-0002.)
* **Debug App Check Token Persistence:** Debug iPhone builds persist a registered App Check debug token in local app `UserDefaults` after launch with `AppCheckDebugToken` or `FIRAAppCheckDebugToken`. Later Debug launches from the app icon restore that token into the process environment before Firebase App Check initializes, so token refreshes do not fall back to an unregistered generated token. If Firebase rejects the restored token, CatVox clears the stored Debug token and reports an app verification failure instead of surfacing Firebase's raw token-exchange response. This bootstrap is compiled out of Release builds; production App Check remains App Attest-only. `make ios-device-launch` passes the registered debug token from local environment variables or `terraform/terraform.tfvars` without printing it. (See ADR-0016.)
* **Secrets:** Zero hardcoded identifiers; all retrieved via Secret Manager at runtime.
* **Service Account: `catvox-backend-sa`** — Runtime identity for Cloud Functions. Holds only the minimal roles required at runtime; never has CI-level access.
    * `roles/aiplatform.user` — invoke Gemini 2.5 Flash via Vertex AI.
    * `roles/storage.objectViewer` — read video objects from GCS for Vertex AI.
    * `roles/storage.objectCreator` — create objects in GCS; required so that signed URLs generated by this SA (via `signBlob`) are honoured by GCS when the iOS client PUTs the video file.
    * `roles/datastore.user` — read/write Firestore usage documents.
    * `roles/secretmanager.secretAccessor` — resolve secrets at function startup.
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
* **Configuration:** The app reads the PostHog project token and host from app-owned `Info.plist` values generated by XcodeGen build settings, with `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` environment variables as local overrides. Missing token configuration must disable analytics gracefully rather than crashing the app. Analytics must also be disabled during XCTest and SwiftUI preview runtimes so CI and previews do not pollute production analytics.
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
CatVox uses named deployment environments. Initial names are `dev` and `prod`, but product code, scripts, CI, and Terraform conventions must treat the environment name as data so future environments can be added without source-level branching. See ADR-0017.

Each environment owns its own GCP/Firebase project, Firebase iOS app, App Check configuration, backend endpoints, PostHog configuration, GitHub secret/variable set, and Terraform state.

Current pre-split defaults continue to point at the existing live-as-Dev backend. Environment-dependent values should be read from build settings, `Info.plist`, environment variables, CI secrets/variables, or explicit backend config files rather than scattered literals in source code.

Initial iOS bundle ID convention:
* `com.kathelix.catvox.dev` for Dev/internal builds
* `com.kathelix.catvox` for App Store Prod

Future Firebase plist convention:
* `GoogleService-Info-<Environment>.plist`
* a build configuration or copy script selects the environment-specific plist before build
* the current committed `CatVox/GoogleService-Info.plist` remains the only plist until the next Firebase app exists

Mutable live integration tests may run only against environments explicitly marked integration-safe. Production deployments get protected non-invasive smoke tests only.

---

## 7. CI/CD Pipelines

### 7.0 Shared Local / CI Command Facade
CatVox uses the repository-root `Makefile` as a thin facade for common developer and CI command bodies. Developers should prefer discoverable `make` targets such as `make ios-test`, `make functions-deploy`, `make functions-integration`, `make terraform-plan`, and `make terraform-apply CONFIRM=apply` over manually retyping long command sequences.

GitHub Actions may call Makefile targets for the command body, but workflow YAML remains responsible for CI-only concerns such as checkout, toolchain installation, dependency caching, Workload Identity Federation authentication, path/event triggers, and PR comments. See ADR-0014.

### 7.1 iOS Build Pipeline
* **Trigger:** Every push and pull request targeting `main`.
* **Runner:** macOS 15 (Xcode 16, iOS 17+ SDK).
* **Steps:** Checkout → install XcodeGen / `xcpretty` → `make ios-generate` → `make ios-build-only` for the generic iOS Simulator slice (`CODE_SIGNING_ALLOWED=NO`) → `make ios-test-only` on a concrete simulator device (`platform=iOS Simulator,name=iPhone 16,OS=latest`). Xcode cannot run tests on `generic/platform=iOS Simulator`.
* **Purpose:** Catches build breaks, XcodeGen drift, and unit-test regressions on every change. No device signing or provisioning profiles required.

### 7.1.1 iOS UI Test Pipeline
* **Local command:** `make ios-ui-test` regenerates the Xcode project and runs the dedicated `CatVoxUITests` XCUITest scheme on a concrete iPhone simulator destination (`IOS_UI_TEST_DESTINATION`, defaulting to `platform=iOS Simulator,name=iPhone 16,OS=latest`).
* **CI trigger:** The Build workflow runs UI tests as a separate job on push to `main` and on manual `workflow_dispatch`, after the normal build/unit-test job passes. Pull requests keep running the cheaper build and unit-test path unless UI coverage is manually requested after merge.
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
* **Variables:** `TF_VAR_project_id` and `TF_VAR_app_check_debug_token` supplied from GitHub Actions secrets; `region` and `firestore_location` use the defaults defined in `variables.tf`.
* **Local apply guard:** Developers must run `make terraform-plan` before review, and local `make terraform-apply` refuses to run unless invoked as `make terraform-apply CONFIRM=apply`. The target still uses Terraform's interactive apply prompt.

### 7.3 Firebase Cloud Functions Pipeline
* **Trigger:** Push or pull request targeting `main` when files under `functions/`, `firebase.json`, `docs/systemInstruction.md`, the repository `Makefile`, or the workflow file itself change. `docs/systemInstruction.md` is included because it is copied into the deployment artifact at build time — a prompt-only change must trigger a redeploy. (See ADR-0008 and ADR-0010.)
* **Authentication:** Same WIF setup as the Terraform pipeline — `catvox-ci-sa` via `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT` secrets.
* **Build job (on PR and push):** `make functions-install` → `make functions-test` (TypeScript compile check plus backend unit tests).
* **Deploy job (on merge to `main`):** Runs after build passes → `make functions-deploy` (`npm --prefix functions run build` plus `firebase deploy --only functions`).
* **Integration job (after merge-to-main deploy):** Runs `make functions-integration` against the currently deployed integration-safe environment, using the current live GCP/Firebase project as `dev` until a separate production environment exists. Integration tests may write temporary Dev data when required and must clean it up. The current suite exchanges the registered App Check debug token for a valid App Check token, verifies that both HTTP Functions reject missing App Check tokens with `401 app_check_unauthorized`, verifies the Firestore quota reservation race contract with temporary `usage/{userId}` data through a direct `@google-cloud/firestore` probe, verifies the machine-readable daily-quota HTTP `429` response and structured Cloud Logging entry, then deletes temporary documents. See ADR-0013, ADR-0015, and ADR-0017.
* **Integration auth boundary:** GitHub Actions WIF produces an external-account Application Default Credentials (ADC) file. Direct data-plane probes in `functions/integration/**` should use Google Cloud client libraries such as `@google-cloud/firestore`, which accept that ADC path. Do not initialize Firebase Admin SDK inside the integration test harness unless it has been explicitly verified under GitHub Actions WIF; Admin ADC loading can reject the CI credentials even when the deployed Cloud Functions runtime uses Firebase Admin correctly.
* **Local Dev integration command:** Developers can run the same backend integration suite against the currently deployed Dev backend with `make functions-integration` or `npm --prefix functions run test:integration`. The Makefile target supplies the current pre-split environment values, sets `CATVOX_INTEGRATION_MUTATIONS_ALLOWED=1` for the integration-safe Dev environment, and preserves an explicitly supplied `CATVOX_APP_CHECK_DEBUG_TOKEN`; when no App Check token environment variable is present, it silently falls back to `app_check_debug_token` in local `terraform/terraform.tfvars` if that file/value exists. Direct `npm --prefix functions run test:integration` runs must provide the required `CATVOX_*` environment values or an integration env file.

### 7.4 WIF Bootstrap & GitHub Secrets
The following one-time manual setup is required before the Terraform pipeline can run. Bootstrap operations are exposed through repository-root Makefile targets:

| Target | Purpose |
|---|---|
| `make bootstrap-remote-state` | Creates the GCS state bucket with versioning |
| `make bootstrap-wif` | Creates the WIF pool + OIDC provider, binds the GitHub repo to `catvox-ci-sa`, grants state bucket access |

**Required GitHub Actions secrets:**

| Secret | Value |
|---|---|
| `GCP_PROJECT_ID` | GCP project ID (`var.project_id`) |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full WIF provider resource name (output of `make bootstrap-wif`) |
| `GCP_SERVICE_ACCOUNT` | `catvox-ci-sa@<project-id>.iam.gserviceaccount.com` |
| `TF_VAR_app_check_debug_token` | Firebase App Check debug token |

Environment-specific GitHub values should be grouped by deployment environment when the split is implemented. Current repository-level secrets remain the pre-split live-as-Dev values.

### 7.5 From-Scratch Environment Runbook

Use this when deploying to a new GCP project, or after a full `terraform destroy`.

#### Prerequisites (one-time per GCP project)
1. Create the GCP project and enable billing — manual, unavoidable.
2. Initialise Firebase on the project:
   ```bash
   firebase projects:addfirebase <PROJECT_ID>
   ```
3. Run the Makefile bootstrap targets:
   ```bash
   GCP_PROJECT_ID=<your-project-id> make bootstrap-remote-state  # creates TF state bucket
   GCP_PROJECT_ID=<your-project-id> make bootstrap-wif            # creates WIF pool + OIDC provider
   ```
4. Add the four GitHub Actions secrets printed by `make bootstrap-wif` (see §7.4).

#### Deploy infrastructure and backend
```bash
# 1. Provision all GCP infrastructure
make terraform-plan
make terraform-apply CONFIRM=apply

# 2. Deploy Cloud Functions
make functions-deploy
```

After step 1 the GitHub Actions CI pipeline is fully functional — all subsequent infrastructure changes go through CI.

#### Known gotchas

| Issue | Cause | Fix |
|---|---|---|
| `terraform apply` fails with 409 on Firestore | `(default)` database is soft-deleted after destroy; GCP retains it for a grace period | `terraform import 'google_firestore_database.default' 'projects/<PROJECT_ID>/databases/(default)'` then re-run apply |
| `terraform destroy` fails on raw videos bucket | Bucket contains objects and `force_destroy = false` | `gcloud storage rm -r "gs://catvox-raw-videos-<PROJECT_ID>/**"` then re-run destroy |
| WIF pool ID conflict after destroy | WIF pools are soft-deleted for 30 days — same ID cannot be reused | WIF pool/provider are intentionally outside Terraform; `bootstrap_wif.sh` only needs to be re-run on a genuinely new GCP project |

---

## 8. Implementation Backlog (MVP)

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

---

## 9. Future Enhancements (Post-MVP)
* **Gemini Model Upgrade:** The backend currently uses `gemini-2.5-flash` (the latest GA Gemini Flash model on Vertex AI as of TRD v2.0). Upgrade to Gemini 3.x Flash once it reaches GA on Vertex AI.
* **Native iPad Support:** Add iPad support as a dedicated post-MVP feature, not as a small target-family change. The iPad implementation must explicitly resolve:
    1. **Orientation Model:** Decide whether iPad is portrait-only for MVP parity with iPhone, or whether CatVox supports a true all-orientation iPad experience.
    2. **Camera Preview and Recording:** Treat app interface orientation, physical device orientation, AVFoundation preview connection orientation, and movie-output orientation as separate concerns. The iPhone portrait-only behavior does not automatically transfer to iPad.
    3. **Rotation UX:** If iPad rotation is supported, use a dedicated camera architecture where the camera surface remains visually stable and controls/layout adapt smoothly, closer to the system Camera app than a simple SwiftUI view rotation.
    4. **Adaptive UI Surfaces:** Verify home, recording, upload/progress, result, history, Photos picker, save-to-Photos, and share-sheet behavior across full-screen iPad, landscape, portrait, and any supported multitasking/windowing modes.
    **Acceptance rule:** CatVox must not claim native iPad support until the iPad camera preview, recorded output orientation, imported-video display, result layout, modal positioning, save/share actions, and rotation behavior pass a real-device regression matrix.
* **Localization / Internationalization:** Add a complete language-localized user experience for supported locales as one unified post-MVP feature, not as separate partial releases. This work includes two required sub-scopes that must ship together:
    1. **Frontend Localization:** Localize all user-facing app interface copy using standard iOS system-language localization, including navigation labels, buttons, alerts, validation messages, quota text, permission usage descriptions, persona display labels, and other user-visible UI strings.
    2. **AI Response Localization:** Localize backend-generated result content by sending the user's preferred locale with analysis requests and requiring returned result fields (`primary_emotion`, `analysis`, `cat_thought`, `owner_tip`) in that language. Persist result-language metadata with saved scans so historical results remain internally consistent.
    **Acceptance rule:** CatVox must not ship a mixed-language experience where app chrome appears in one language while AI-generated result content appears in another.
* **IAM Security Review:** `catvox-ci-sa` currently holds `roles/editor`, `roles/resourcemanager.projectIamAdmin`, `roles/iam.serviceAccountAdmin`, and `roles/secretmanager.secretAccessor` — broad rights required for Terraform to manage IAM bindings via CI. Consider splitting Terraform into an admin layer (IAM, SAs — applied manually or via a privileged gated workflow) and an infra layer (GCS, Firestore, Artifact Registry — applied by CI with `roles/editor` only), removing the need for `projectIamAdmin` and `serviceAccountAdmin` on the routine CI identity.
* **PostHog Analytics:**
    1. **Dashboard-as-Code:** Move PostHog dashboard and insight definitions into Terraform after MVP so analytics configuration is reproducible and reviewed in git. Prefer a separate Terraform root such as `terraform/posthog/` with its own state prefix and `POSTHOG_API_KEY` CI secret, rather than mixing PostHog credentials into the GCP infrastructure root. Initial scope should import the existing analytics dashboard and wizard-created insights, correct share-event semantics (`share_sheet_opened` for sheet presentation, `scan_shared` for completed share actions), and manage the core MVP dashboard tiles for scan conversion, Photos validation failures, share/export conversion, save-to-Photos conversion, and quota pressure.
    2. **Analytics Environment Separation:** Separate development and production analytics traffic, either by using distinct Debug/Release PostHog projects or by attaching an `app_environment` property to every event so test traffic can be excluded from production dashboards.
    3. **Collect in-app feedback**: from users, automatic sending of errors, special "Feedback" dialog
* **Picker Eligibility UX:** Consider richer pre-selection eligibility hints or a more advanced gallery experience only if later product testing shows clear value over the simpler MVP rejection flow.
* **Signed URL Issuance Rate-Limit:** Add a dedicated anti-abuse rate-limit for signed upload URL requests if App Check plus upload-gate quota enforcement prove insufficient.
* **Analysis Request Idempotency:** Design idempotent `analyseVideo` semantics before adding automatic client retries for analysis POST failures. The design should prevent duplicate Vertex AI calls, quota increments, or user-visible duplicate scans when the backend finishes after the client loses the connection.
* **Backend Analysis Timing Telemetry:** Add structured timing logs around `analyseVideo` phases, including App Check pass, quota pre-check, GCS metadata lookup, Gemini request start/end, response validation, quota increment, and final response status, so slow device-observed analysis runs can be attributed without relying on Xcode networking logs.
* **Backend Duration Validation:** Add backend validation for uploaded video duration <= 10 seconds before Vertex AI is invoked, rather than relying only on client-side duration checks.
* **4K Import Strategy Review:** Re-evaluate cost and UX trade-offs of accepting 4K gallery videos, and decide later whether to keep raw upload, cap imported resolution, or introduce client-side normalization.
* **Failure Reporting UX Review:** Review likely user-visible failure points across the app and design one simple, consistent way for users to report failures without adding bespoke report flows to individual screens. Example failure points should include failure to open a saved video on the Result screen, including the case where the Result screen uses the original local clip as its looping background. The future design should also decide what diagnostic context to capture internally for such failures.
* **Haptic Completion:** Tactile feedback on successful AI interpretation.
* **Multi-Cat Profiles:** Specific tracking for different pets.
* **Health Monitoring:** Advanced analysis for subtle pain or distress markers.
* **Social Feed:** A community "Wall of Meows" to see global cat interpretations.
* **Advanced Mood Analytics:** Week-over-week trends for cat behavior.
* **4K Video (Pro Tier):** Unlock 4K capture for Pro subscribers; free tier remains capped at 1080p.
