# High-level Design: CatVox AI

**Version:** 1.8
**Company:** Kathelix Ltd
**Project Lead:** Ivan Boyko
**Date:** 29 April 2026

This file captures the high-level architecture and stable design intent for CatVox.
It should stay concise and remain aligned with `docs/TRD.md`, which holds the detailed technical design and implementation constraints.
For formal architecture decisions, see `docs/adr/README.md` and the ADR files under `docs/adr/`.

## 1. Project Context & Vision
CatVox AI is a premium iOS application and brand ambassador for Kathelix Ltd. It uses multimodal AI (Gemini 2.5 Flash) to interpret short cat video clips, providing behavioral analysis and a humorous "inner monologue" translation based on specific feline personas.

The MVP supports two local input sources:
1. recording a new clip in-app, with the ability to stop early once a brief minimum capture threshold is reached
2. selecting an existing clip from the user's Photos library

The product also includes a local on-device scan history as part of the MVP user experience. Each successful scan is treated as a reusable memory artifact that preserves the original cat moment together with its AI interpretation, allowing users to revisit previous results without relying on cloud-side user accounts.

The MVP also supports on-demand creation of a funny shareable result video derived from a saved scan. The original preserved clip remains untouched; CatVox generates a separate export-ready video locally on the device with branded overlays and lets the user save or share that derived output when they explicitly ask for it.

## 2. System Flow
1. The user taps the primary CTA `Read My Cat` in the iOS app.
2. The app presents a lightweight source choice sheet with:
   * `Record New Video`
   * `Choose from Photos`
3. The user provides a local video by either recording a new clip or selecting an existing clip from Photos.
4. For in-app recording, the app records up to 10 seconds and allows the user to stop early after a short minimum capture threshold.
5. After recording ends, the app presents a lightweight review decision:
   * `Retake`
   * `Use This Clip`
6. The app validates the selected local video against MVP client-side rules before upload.
7. The app requests a signed upload URL from the backend.
8. The app uploads the validated video to Google Cloud Storage.
9. The app submits the uploaded clip for backend analysis using the server-issued storage reference.
10. The backend validates App Check, enforces usage limits, validates server-side guardrails such as upload file size, invokes Vertex AI, and returns a normalized result payload.
11. After a successful analysis, the app saves the scan locally as a history item that includes the original clip and the AI result.
12. The user views the completed result against the original local clip as the visual background, preserving the full frame with ambient styling when needed, then returns to Home via a lightweight completion action.
13. From the completed result experience, the user can optionally generate a separate shareable video derived from the preserved local clip and CatVox interpretation.
14. The user can save or share that derived video, while the original preserved clip remains unchanged.
15. The user can revisit past scans through a local history view on Home that presents previous results as reusable memories, reopening them against the same preserved local clip with the same fitted full-frame presentation and offering the same on-demand share export path.

## 3. Core Strategic Priorities
* **Resilient Infrastructure:** The system is built on Google Cloud Platform (GCP) using a "Phoenix" architecture - reproducible, secure, and tool-driven.
* **User Experience:** Focus on "Glassmorphism" design, minimalist interactions, and high-performance video processing.
* **Memorable History:** The product should preserve emotionally valuable cat moments as durable, revisit-able memories rather than disposable one-time AI responses.
* **Monetization:** A freemium model with server-enforced daily usage limits and a StoreKit 2-based Pro tier for unlimited use.

## 4. Key Design Decisions
* **Multimodal Engine:** Selected Gemini 2.5 Flash for its ability to process video and audio simultaneously via GCS-hosted media, reducing mobile device memory overhead.
* **Video Pipeline:** The MVP accepts validated local videos from either in-app recording or Photos selection. In-app recording captures up to 10 seconds, with support for early user stop after a short minimum threshold, followed by a lightweight `Retake` / `Use This Clip` review step before upload. Native HEVC (.mov) at 1080p remains the preferred capture path for in-app recording, with silent fallback to H.264 on devices that do not support HEVC. Client-side transcoding is intentionally out of scope for MVP.
* **Scan Memory Model:** A completed scan is conceptually a durable bundle of the original clip and the structured AI interpretation. This bundled record is the canonical unit of local history.
* **MVP Input Rules:** Submitted videos must already satisfy MVP limits before upload: maximum 10 seconds duration, maximum 100 MB file size, supported codec/container, and no ProRes input. 4K input is temporarily accepted for simplicity.
* **UX Validation Strategy:** The app validates candidate videos locally before upload and clearly explains rejection reasons when a selected video is ineligible. In-app trimming is out of scope for MVP.
* **History Reliability Over External References:** For MVP, scan history should remain self-contained and reliable even if the user later removes the source video from Photos. The app should therefore preserve its own app-local copy of the original clip for successful scans rather than depending solely on a Photos-library reference.
* **Clip-Centric Result Presentation:** The original preserved local clip remains the canonical visual context for a scan. The completed result experience, including reopened history items, should present the interpretation against that same local clip, preserving the full original frame and using ambient styling around it when needed rather than cropping the clip to force edge-to-edge fill.
* **History-First Presentation:** The history experience lives on Home as a simple, browsable list of past scans. Each entry represents one preserved clip and should surface a thumbnail together with lightweight interpretation cues so the user can quickly recognize and reopen a prior memory.
* **Derived Share Export:** Shareable video output is a derived artifact created from a saved scan, never a mutation of the original preserved clip. The share path should always treat the original clip as canonical and leave it untouched. See ADR-0009.
* **On-Device Share Rendering:** Shareable exports are rendered locally on iOS rather than by backend infrastructure. This keeps the share feature privacy-preserving, reduces cloud cost, and allows previously saved scans to be re-rendered on demand without another upload. See ADR-0009.
* **On-Demand Export Only:** The app does not auto-render share videos for every completed scan. A derived export is generated only when the user explicitly asks to save or share it.
* **MVP Share Style Simplicity:** The first share export style keeps the original aspect ratio and overlays the cat thought as the hero element together with lightweight persona, emotion, and CatVox/Kathelix branding. The share overlay should scale proportionally from the actual rendered frame so the visual hierarchy remains consistent across portrait, landscape, square, HD, and 4K clips. Multiple style packs and fixed social-format reframing are deferred.
* **Regional Strategy:** Standardized on `us-central1` (Iowa) for the lowest AI infrastructure costs and `nam5` for Firestore multi-region durability across the US market.
* **Environment Configuration:** CatVox uses named environments. The first environments are `dev` and `prod`, but code and automation should treat the environment name as configuration data so future environments can be added without source-level branching. Each environment owns separate Firebase/GCP, App Check, backend endpoint, analytics, CI auth identity, and Terraform-state configuration. Committed `config/environments/<environment>.xcconfig` files are the source of truth for non-secret environment values; GitHub Environment secrets and ignored tfvars files hold only true secrets or deliberately private values. Analytics isolation follows the same per-environment separation model. See ADR-0017, ADR-0018, ADR-0019, ADR-0020, and ADR-0021.
* **Security:** Firebase App Check uses App Attest for production iOS app verification and Debug Provider for local development, preventing unauthorized API calls and managing GCP costs.
* **Backend Pattern:** Firebase Cloud Functions (2nd Gen) act as the backend proxy between the iOS client and privileged GCP services.
* **Prompt Management:** The AI system prompt is maintained as a versioned markdown document in the repository and treated as part of the deployable backend behavior.
* **Identity Separation:** Runtime cloud execution and automated infrastructure delivery use separate service accounts to reduce blast radius and keep privileged automation isolated from application runtime.
* **Product Analytics:** MVP product analytics use PostHog to measure scan-funnel health, Photos-import validation, quota pressure, share/export behavior, and upgrade intent. Analytics use the same anonymous per-install UUID as quota enforcement and must not include raw video, AI-generated cat thoughts, file paths, or Photos asset identifiers. PostHog projects map 1:1 to CatVox environments — Dev and Prod analytics use separate PostHog projects bound to the same environment as the matching app build and backend, with `app_environment` retained as defense-in-depth metadata. See ADR-0011, ADR-0019, and ADR-0020.

## 5. Trust Boundary
* The iOS client never calls Vertex AI directly.
* Signed upload URL issuance is server-side only.
* Firebase App Check is mandatory on backend entry points.
* Usage policy enforcement is server-side.
* Secrets and privileged cloud access stay server-side.
* Product analytics are limited to product-event metadata and anonymous per-install identity.
* Client-side validation improves UX and is the primary MVP enforcement point for duration/format eligibility, while the backend remains authoritative for server-side guardrails such as quota and upload file size.

## 6. Infrastructure Model
* CatVox runs on GCP and is provisioned with Terraform.
* The infrastructure model is intended to be reproducible and rebuildable.
* The project uses three distinct CI/CD pipelines: iOS build validation, infrastructure delivery, and backend function delivery.
* CI/CD authentication uses keyless GitHub Actions federation.
* `kathelix-catvox-dev` is the active Dev / integration-testing project. `kathelix-catvox-prod` is the Prod environment project, being provisioned for production; pre-split Dev leftovers were cleaned from it beforehand. See ADR-0017 and ADR-0018.

## 7. MVP Boundaries / Non-goals
* No direct client-side access to privileged GCP services.
* No client-side video transcoding in MVP.
* No in-app video trimming in MVP.
* No post-capture trimming or clip editing in MVP beyond `Retake` or `Use This Clip`.
* No backend rendering of shareable result videos in MVP.
* No automatic post-scan rendering of shareable videos in MVP.
* No multiple share-video style packs or fixed social-format reframing in MVP.
* No backend video-duration validation in MVP; duration is enforced client-side, with server-side upload file-size guardrails only.
* No custom filtered gallery browser in MVP beyond the system video picker flow.
* No native iPad support in MVP. CatVox should not claim iPad support until iPad-specific orientation, camera preview, adaptive layout, picker, and share flows have been designed and tested on real iPad hardware.
* User identity for MVP is an anonymous per-install identifier used for quota enforcement; full authenticated user accounts are outside current MVP scope.
* Older Apple device compatibility is not a design driver for the attestation approach.

---
