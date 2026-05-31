###############################################################################
# CatVox AI — PostHog insights for the Analytics basics dashboard.
#
# Each `query_json` is the authoritative query definition for its insight. These
# five tiles are the normalized MVP dashboard-as-code surface for every CatVox
# environment.
###############################################################################

resource "posthog_insight" "scan_conversion_funnel" {
  project_id    = tostring(posthog_project.this.id)
  name          = "Scan conversion funnel"
  description   = "Core funnel from source selection through local validation to completed analysis."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "FunnelsQuery"
      series = [
        { kind = "EventsNode", name = "Source chosen", event = "scan_source_chosen" },
        { kind = "EventsNode", name = "Video validation passed", event = "video_validation_passed" },
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

resource "posthog_insight" "photos_validation_failures" {
  project_id    = tostring(posthog_project.this.id)
  name          = "Photos validation failures"
  description   = "Rejected Photos selections grouped by local validation reason."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "TrendsQuery"
      series = [
        { kind = "EventsNode", math = "total", name = "Validation failures", event = "video_validation_failed" },
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
      breakdownFilter = {
        breakdown      = "validation_failure_reason"
        breakdown_type = "event"
      }
      filterTestAccounts = false
    }
  })
}

resource "posthog_insight" "share_export_conversion" {
  project_id    = tostring(posthog_project.this.id)
  name          = "Share export conversion"
  description   = "Funnel from share-export render start through share sheet presentation to completed share."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "FunnelsQuery"
      series = [
        { kind = "EventsNode", name = "Export started", event = "share_export_started" },
        { kind = "EventsNode", name = "Share sheet opened", event = "share_sheet_opened" },
        { kind = "EventsNode", name = "Share completed", event = "scan_shared" },
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

resource "posthog_insight" "quota_pressure" {
  project_id    = tostring(posthog_project.this.id)
  name          = "Quota pressure & upgrade intent"
  description   = "Tracks quota-card exposure by trigger alongside upgrade intent."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "TrendsQuery"
      series = [
        { kind = "EventsNode", math = "total", name = "Quota card shown", event = "quota_card_shown" },
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
      breakdownFilter = {
        breakdown      = "trigger"
        breakdown_type = "event"
      }
      filterTestAccounts = false
    }
  })
}

resource "posthog_insight" "save_to_photos_conversion" {
  project_id    = tostring(posthog_project.this.id)
  name          = "Save-to-Photos conversion"
  description   = "Funnel from share-export render start to successful Photos save."
  dashboard_ids = [posthog_dashboard.analytics_basics.id]

  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind = "FunnelsQuery"
      series = [
        { kind = "EventsNode", name = "Export started", event = "share_export_started" },
        { kind = "EventsNode", name = "Saved to Photos", event = "scan_saved_to_photos" },
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
