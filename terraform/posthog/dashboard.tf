###############################################################################
# CatVox AI — PostHog Analytics Basics dashboard + layout
# Imported from the wizard-created Dev dashboard for issue #37 Slice 4.
#
# `posthog_dashboard_layout` is fully authoritative over tile membership — the
# tile list below must match the live tile set on the dashboard, in the order
# the PostHog API returns it (descending tile_id). Slice 5 will normalise this
# into a reusable per-environment definition shared with Prod; this slice only
# captures the current state with zero drift.
###############################################################################

resource "posthog_dashboard" "analytics_basics" {
  name        = "Analytics basics"
  description = "Core CatVox product analytics: scan funnel, analysis outcomes, quota pressure, and share behaviour."
  pinned      = true
}

import {
  to = posthog_dashboard.analytics_basics
  id = "${var.posthog_project_id}/1524032"
}

resource "posthog_dashboard_layout" "analytics_basics" {
  dashboard_id = posthog_dashboard.analytics_basics.id

  # Tile order matches PostHog API order (descending tile_id) so the first plan
  # after import shows zero drift. Reordering is a Slice 5 concern.
  tiles = [
    { insight_id = posthog_insight.scan_share_actions.id },
    { insight_id = posthog_insight.quota_pressure.id },
    { insight_id = posthog_insight.top_cat_personas.id },
    { insight_id = posthog_insight.daily_scan_volume.id },
    { insight_id = posthog_insight.scan_conversion_funnel.id },
  ]
}

import {
  to = posthog_dashboard_layout.analytics_basics
  id = "${var.posthog_project_id}/1524032"
}
