###############################################################################
# CatVox AI — PostHog Analytics Basics dashboard + layout
#
# `posthog_dashboard_layout` is fully authoritative over tile membership — any
# tile not declared here is unmanaged after apply. The tile order follows the
# MVP analytics reading flow: acquisition, validation, sharing, saving, quota.
###############################################################################

resource "posthog_dashboard" "analytics_basics" {
  project_id  = tostring(posthog_project.this.id)
  name        = "Analytics basics"
  description = "Core CatVox product analytics: scan funnel, Photos validation, share/export conversion, save-to-Photos conversion, and quota pressure."
  pinned      = true
}

resource "posthog_dashboard_layout" "analytics_basics" {
  project_id   = tostring(posthog_project.this.id)
  dashboard_id = posthog_dashboard.analytics_basics.id

  tiles = [
    { insight_id = posthog_insight.scan_conversion_funnel.id },
    { insight_id = posthog_insight.photos_validation_failures.id },
    { insight_id = posthog_insight.share_export_conversion.id },
    { insight_id = posthog_insight.save_to_photos_conversion.id },
    { insight_id = posthog_insight.quota_pressure.id },
  ]
}
