###############################################################################
# CatVox AI — PostHog insights for the Analytics basics dashboard.
#
# Each `query_json` is the authoritative query definition for its insight. The
# definitions still reflect the original wizard choices — including the
# mis-labelled "Share sheet" series on `scan_share_actions` that actually
# captures `scan_shared` (completed shares) rather than `share_sheet_opened`
# (sheet presentations). Slice 5 will rewrite share semantics.
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
