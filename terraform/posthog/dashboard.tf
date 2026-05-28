###############################################################################
# CatVox AI — PostHog Analytics Basics dashboard + layout
#
# `posthog_dashboard_layout` is fully authoritative over tile membership — any
# tile not declared here is unmanaged after apply. The tile order below was
# fixed to match the PostHog API order from the original Dev import (descending
# tile_id) so the first apply was zero-drift; that order is preserved for now
# and Slice 5 will revisit it alongside the share-semantics rewrite.
###############################################################################

resource "posthog_dashboard" "analytics_basics" {
  name        = "Analytics basics"
  description = "Core CatVox product analytics: scan funnel, analysis outcomes, quota pressure, and share behaviour."
  pinned      = true
}

resource "posthog_dashboard_layout" "analytics_basics" {
  dashboard_id = posthog_dashboard.analytics_basics.id

  tiles = [
    { insight_id = posthog_insight.scan_share_actions.id },
    { insight_id = posthog_insight.quota_pressure.id },
    { insight_id = posthog_insight.top_cat_personas.id },
    { insight_id = posthog_insight.daily_scan_volume.id },
    { insight_id = posthog_insight.scan_conversion_funnel.id },
  ]
}
