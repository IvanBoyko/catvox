###############################################################################
# CatVox AI — PostHog Terraform Outputs
#
# Surfaces environment identity plus the imported project, dashboard, and
# insight IDs so consumers can cross-check Terraform state against the live
# PostHog UI without re-querying.
###############################################################################

output "environment_name" {
  description = "CatVox environment this PostHog Terraform state targets."
  value       = var.environment_name
}

output "posthog_api_host" {
  description = "PostHog API host this state targets."
  value       = var.posthog_api_host
}

output "posthog_project_id" {
  description = "PostHog project ID this state targets."
  value       = var.posthog_project_id
}

output "posthog_organization_id" {
  description = "PostHog organization ID this state targets."
  value       = var.posthog_organization_id
}

output "project_id" {
  description = "Numeric ID of the imported PostHog project."
  value       = posthog_project.this.id
}

output "analytics_basics_dashboard_id" {
  description = "Numeric ID of the imported Analytics basics dashboard."
  value       = posthog_dashboard.analytics_basics.id
}

output "insight_ids" {
  description = "Numeric IDs of the imported wizard-created insights keyed by HCL resource name."
  value = {
    scan_conversion_funnel = posthog_insight.scan_conversion_funnel.id
    daily_scan_volume      = posthog_insight.daily_scan_volume.id
    top_cat_personas       = posthog_insight.top_cat_personas.id
    quota_pressure         = posthog_insight.quota_pressure.id
    scan_share_actions     = posthog_insight.scan_share_actions.id
  }
}
