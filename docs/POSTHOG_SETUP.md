# PostHog setup

PostHog analytics are integrated through the repo-owned XcodeGen workflow.
The SDK package is declared in `project.yml`, app configuration is generated
into `Info.plist`, and runtime calls go through `AnalyticsService` instead of
direct `PostHogSDK.shared.capture(...)` calls in views.

Analytics identify the user with CatVox's existing anonymous per-install UUID
from `UserIdentityStore`, matching the identifier used for quota enforcement.
If the PostHog project token is missing, analytics are disabled without
crashing the app. Analytics are also disabled during XCTest and SwiftUI previews
to keep automated verification out of analytics dashboards.

CatVox uses explicit product events only. PostHog automatic lifecycle capture,
screen-view capture, element autocapture, rage-click capture, surveys, session
replay, feature-flag preloading, default person properties, and crash autocapture
are disabled in `AnalyticsService`.

In-app user feedback and error/crash intake are intentionally out of scope for
this analytics epic; the tool/path decision (PostHog Surveys/Error Tracking vs a
standalone SaaS vs a custom backend endpoint) is tracked in #123.

## Environments

CatVox runs one PostHog project per named environment. Every project is managed
from the same `terraform/posthog` definitions, so each environment has the same
"Analytics basics" dashboard and 5 insights.

| Environment | PostHog project | Project ID | App config | Analytics dashboard |
|---|---|---|---|---|
| `dev` | `CatVox Dev` | `402530` | `config/environments/dev.xcconfig` | [dashboard](https://us.posthog.com/project/402530/dashboard/1524032) |
| `prod` | `CatVox Prod` | `448206` | `config/environments/prod.xcconfig` | [dashboard](https://us.posthog.com/project/448206/dashboard/1650824) |

Per ADR-0019, separate projects per environment are the primary isolation
boundary; the `app_environment` property required on every event is
defense-in-depth metadata on top of that. Each environment's app reads its own
public project token from `CATVOX_POSTHOG_PROJECT_TOKEN` in its xcconfig — a
`phc_` ingestion key that is safe to commit by design (see ADR-0020). The
operational PostHog API key is never committed; it lives only in the matching
GitHub Environment secret.

New environments are provisioned with `make posthog-environment-provision`,
which applies `terraform/posthog` (HCL → `terraform apply` → PostHog; no UI
wizard, no import) and writes the resulting project id and token back into the
environment xcconfig. See `terraform/posthog/README.md` for the full sequence,
`dashboard.tf` / `insights.tf` for the authoritative definitions, and ADR-0019
and ADR-0020.

## Events

| Event | Description | Key properties |
|-------|-------------|----------------|
| `scan_source_chosen` | User chooses record or Photos from the source sheet. | `source` |
| `photos_picker_opened` | Photos picker is presented. | - |
| `photos_picker_cancelled` | Picker is dismissed without a selected video. | - |
| `photos_clip_selected` | User selects a video in the Photos picker. | - |
| `video_validation_passed` | Candidate video passes local validation. | `source_type` |
| `video_validation_failed` | Candidate video fails local validation. | `source_type`, `validation_failure_reason` |
| `recording_started` | User starts recording in the camera view. | - |
| `recording_finished` | Recording reaches review state. | - |
| `recording_retake_tapped` | User discards the recorded clip and returns to camera. | - |
| `recording_cancelled` | User exits the recording flow without accepting a clip. | `capture_state`, `recorded_clip_available` |
| `recording_completed` | User accepts a recorded clip with "Use This Clip". | `source_type` |
| `analysis_completed` | Backend/mock pipeline returns a successful result and the scan is saved. | `persona_type`, `primary_emotion`, `confidence_score`, `source_type` |
| `analysis_failed` | Upload or analysis pipeline fails. | `error_message` |
| `analysis_retry_tapped` | User retries after an upload/analysis failure. | - |
| `quota_exceeded` | Server returns HTTP 429. | - |
| `quota_card_shown` | Quota card is displayed from local or server quota state. | `trigger` |
| `share_export_started` | On-device share render starts. | `action`, `scan_id` |
| `share_export_render_failed` | On-device share render fails. | `action`, `scan_id`, `error_type` |
| `share_sheet_opened` | System share sheet is presented for a rendered video. | `scan_id` |
| `scan_shared` | User completes a share-sheet action. | `scan_id`, `activity_type` |
| `share_sheet_cancelled` | User cancels or exits the share sheet. | `scan_id`, `activity_type` |
| `scan_saved_to_photos` | Rendered share video is saved to Photos. | `scan_id` |
| `photos_permission_denied` | Save-to-Photos cannot proceed because add permission is denied. | `scan_id` |
| `share_save_failed` | Save-to-Photos fails. | `scan_id`, `error_type` |
| `scan_deleted` | User confirms deletion of a saved scan. | `persona_type` |
| `upgrade_to_pro_tapped` | User taps the quota-card Pro CTA. | - |

## Managed MVP Dashboard Tiles

- Scan conversion:
  `scan_source_chosen` -> `video_validation_passed` -> `analysis_completed`.
- Photos validation failures:
  trend of `video_validation_failed` grouped by `validation_failure_reason`.
- Share/export conversion:
  `share_export_started` -> `share_sheet_opened` -> `scan_shared`.
- Save-to-Photos conversion:
  `share_export_started` -> `scan_saved_to_photos`.
- Quota pressure:
  trend of `quota_card_shown` grouped by `trigger`, with `upgrade_to_pro_tapped`
  as the conversion event.

The dashboard and all 5 insights are Terraform-managed under `terraform/posthog/`
— see `dashboard.tf` and `insights.tf` for the authoritative HCL definitions,
and `terraform/posthog/README.md` for the per-environment provisioning sequence.
