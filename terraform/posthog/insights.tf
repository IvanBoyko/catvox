###############################################################################
# CatVox AI — PostHog wizard-created insights for the Analytics basics dashboard.
# Imported from the live CatVox Dev project for issue #37 Slice 4.
#
# Each `query_json` mirrors the current server query verbatim so the first plan
# shows zero drift. The wizard semantics deliberately preserve their original
# event choices — including the mis-labelled "Share sheet" series on
# scan_share_actions, which uses `scan_shared` rather than `share_sheet_opened`.
# Slice 5 will rewrite share semantics; Slice 4 only captures current state.
###############################################################################

resource "posthog_insight" "scan_conversion_funnel" {
  name          = "Scan conversion funnel"
  description   = "Core funnel from source selection through to completed analysis."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "FunnelsQuery"
      series = [
        { kind = "EventsNode", name = "Source chosen", event = "scan_source_chosen" },
        { kind = "EventsNode", name = "Recording completed", event = "recording_completed" },
        { kind = "EventsNode", name = "Analysis completed", event = "analysis_completed" },
      ]
      dateRange  = { date_from = "-30d", explicitDate = false }
      properties = []
      funnelsFilter = {
        layout                   = "vertical"
        exclusions               = []
        funnelVizType            = "steps"
        funnelOrderType          = "ordered"
        showValuesOnSeries       = false
        funnelStepReference      = "total"
        funnelWindowInterval     = 14
        breakdownAttributionType = "first_touch"
        funnelWindowIntervalUnit = "day"
      }
      filterTestAccounts = false
    }
  })
}

import {
  to = posthog_insight.scan_conversion_funnel
  id = "${var.posthog_project_id}/8262447"
}

resource "posthog_insight" "daily_scan_volume" {
  name          = "Daily scan volume"
  description   = "Number of analyses completed per day — the primary usage metric."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "TrendsQuery"
      series = [
        { kind = "EventsNode", math = "total", name = "Analyses completed", event = "analysis_completed" },
      ]
      interval   = "day"
      dateRange  = { date_from = "-30d", explicitDate = false }
      properties = []
      trendsFilter = {
        display                 = "ActionsLineGraph"
        showLegend              = false
        hideWeekends            = false
        yAxisScaleType          = "linear"
        showMultipleYAxes       = false
        showValuesOnSeries      = false
        smoothingIntervals      = 1
        showPercentStackView    = false
        aggregationAxisFormat   = "numeric"
        resultCustomizationBy   = "value"
        excludeBoxPlotOutliers  = true
        showAlertThresholdLines = false
      }
      filterTestAccounts = false
    }
  })
}

import {
  to = posthog_insight.daily_scan_volume
  id = "${var.posthog_project_id}/8262449"
}

resource "posthog_insight" "top_cat_personas" {
  name          = "Top cat personas"
  description   = "Distribution of analysis results by persona_type — shows which cat moods dominate."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "TrendsQuery"
      series = [
        { kind = "EventsNode", math = "total", name = "Analyses", event = "analysis_completed" },
      ]
      interval   = "day"
      dateRange  = { date_from = "-30d", explicitDate = false }
      properties = []
      trendsFilter = {
        display                 = "ActionsBar"
        showLegend              = false
        hideWeekends            = false
        yAxisScaleType          = "linear"
        showMultipleYAxes       = false
        showValuesOnSeries      = false
        smoothingIntervals      = 1
        showPercentStackView    = false
        aggregationAxisFormat   = "numeric"
        resultCustomizationBy   = "value"
        excludeBoxPlotOutliers  = true
        showAlertThresholdLines = false
      }
      breakdownFilter = {
        breakdown      = "persona_type"
        breakdown_type = "event"
      }
      filterTestAccounts = false
    }
  })
}

import {
  to = posthog_insight.top_cat_personas
  id = "${var.posthog_project_id}/8262450"
}

resource "posthog_insight" "quota_pressure" {
  name          = "Quota pressure & upgrade intent"
  description   = "Tracks quota_exceeded events alongside upgrade_to_pro_tapped — key monetisation signal."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "TrendsQuery"
      series = [
        { kind = "EventsNode", math = "total", name = "Quota hit", event = "quota_exceeded" },
        { kind = "EventsNode", math = "total", name = "Upgrade tapped", event = "upgrade_to_pro_tapped" },
      ]
      interval   = "day"
      dateRange  = { date_from = "-30d", explicitDate = false }
      properties = []
      trendsFilter = {
        display                 = "ActionsLineGraph"
        showLegend              = false
        hideWeekends            = false
        yAxisScaleType          = "linear"
        showMultipleYAxes       = false
        showValuesOnSeries      = false
        smoothingIntervals      = 1
        showPercentStackView    = false
        aggregationAxisFormat   = "numeric"
        resultCustomizationBy   = "value"
        excludeBoxPlotOutliers  = true
        showAlertThresholdLines = false
      }
      filterTestAccounts = false
    }
  })
}

import {
  to = posthog_insight.quota_pressure
  id = "${var.posthog_project_id}/8262452"
}

resource "posthog_insight" "scan_share_actions" {
  name          = "Scan share actions"
  description   = "Share sheet opens vs. Photos saves — measures post-scan engagement and viral potential."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "TrendsQuery"
      series = [
        { kind = "EventsNode", math = "total", name = "Share sheet", event = "scan_shared" },
        { kind = "EventsNode", math = "total", name = "Saved to Photos", event = "scan_saved_to_photos" },
      ]
      interval   = "day"
      dateRange  = { date_from = "-30d", explicitDate = false }
      properties = []
      trendsFilter = {
        display                 = "ActionsBar"
        showLegend              = false
        hideWeekends            = false
        yAxisScaleType          = "linear"
        showMultipleYAxes       = false
        showValuesOnSeries      = false
        smoothingIntervals      = 1
        showPercentStackView    = false
        aggregationAxisFormat   = "numeric"
        resultCustomizationBy   = "value"
        excludeBoxPlotOutliers  = true
        showAlertThresholdLines = false
      }
      filterTestAccounts = false
    }
  })
}

import {
  to = posthog_insight.scan_share_actions
  id = "${var.posthog_project_id}/8262453"
}
