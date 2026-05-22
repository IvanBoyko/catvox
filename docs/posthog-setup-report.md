# PostHog setup report

PostHog analytics are integrated through the repo-owned XcodeGen workflow.
The SDK package is declared in `project.yml`, app configuration is generated
into `Info.plist`, and runtime calls go through `AnalyticsService` instead of
direct `PostHogSDK.shared.capture(...)` calls in views.

Analytics identify the user with CatVox's existing anonymous per-install UUID
from `UserIdentityStore`, matching the identifier used for quota enforcement.
If the PostHog project token is missing, analytics are disabled without
crashing the app. Analytics are also disabled during XCTest and SwiftUI previews
to keep automated verification out of analytics dashboards.

The current PostHog project is `CatVox Dev`. Per ADR-0019, real production
analytics must use a separate `CatVox Prod` project. The `app_environment`
property remains required on every event as defense-in-depth metadata, but
separate projects are the primary Dev/Prod isolation boundary.

CatVox uses explicit product events only. PostHog automatic lifecycle capture,
screen-view capture, element autocapture, rage-click capture, surveys, session
replay, feature-flag preloading, default person properties, and crash autocapture
are disabled in `AnalyticsService`.

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

## Dev Dashboard Links From Wizard

- **Dashboard - Analytics basics**: https://us.posthog.com/project/402530/dashboard/1524032
- **Scan conversion funnel**: https://us.posthog.com/project/402530/insights/HpsroXVQ
- **Daily scan volume**: https://us.posthog.com/project/402530/insights/3ZD4bnzS
- **Top cat personas**: https://us.posthog.com/project/402530/insights/kB5Hjls2
- **Quota pressure & upgrade intent**: https://us.posthog.com/project/402530/insights/brptiNF5
- **Scan share actions**: https://us.posthog.com/project/402530/insights/5dK5T6k9

These dashboard definitions may need to be refreshed because `scan_shared` now
means a completed share action, while `share_sheet_opened` tracks sheet
presentation.

These links are Dev-only references for the current `CatVox Dev` project. The
`terraform/posthog/` root now exists (issue #37 Slice 3) but declares no PostHog
resources yet. Slice 4 imports the Dev project, its dashboard, and the
wizard-created insights; Slice 5 normalises those definitions into reusable
Terraform that reproduces the managed MVP dashboard shape for `CatVox Prod`
without sharing Dev project state or credentials. See ADR-0019 and ADR-0020.

## Dashboard Refresh Notes

Refresh the wizard-created PostHog insights so they match CatVox's final event
semantics:

1. Open each linked insight from **Dashboard - Analytics basics**.
2. For share-sheet presentation counts, use `share_sheet_opened`.
3. For completed share counts, use `scan_shared`.
4. For save-to-Photos success counts, use `scan_saved_to_photos`.
5. For failure monitoring, use `share_export_render_failed`,
   `share_save_failed`, and `photos_permission_denied`.
6. Save the edited insight and update the dashboard tile title if the event
   meaning changed.

Suggested MVP dashboard tiles:

- Scan conversion funnel:
  `scan_source_chosen` -> `video_validation_passed` -> `analysis_completed`.
- Photos import validation:
  trend of `video_validation_failed` grouped by `validation_failure_reason`.
- Share conversion funnel:
  `share_export_started` -> `share_sheet_opened` -> `scan_shared`.
- Save-to-Photos conversion:
  `share_export_started` -> `scan_saved_to_photos`.
- Quota pressure:
  trend of `quota_card_shown` grouped by `trigger`, with `upgrade_to_pro_tapped`
  as the conversion event.
