###############################################################################
# CatVox AI — PostHog Terraform Outputs
#
# Surfaces environment identity plus the managed project, dashboard, and insight
# IDs so consumers can cross-check Terraform state against the live PostHog UI
# without re-querying. The project API token is sensitive but app-visible; local
# writeback automation uses it to fill the environment xcconfig after bootstrap.
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
  description = "Numeric ID of the managed PostHog project."
  value       = posthog_project.this.id
}

output "project_api_token" {
  description = "Public PostHog ingestion token for this project. Sensitive in Terraform output, but safe to commit into the app xcconfig as the client analytics token."
  value       = posthog_project.this.api_token
  sensitive   = true
}

output "analytics_basics_dashboard_id" {
  description = "Numeric ID of the managed Analytics basics dashboard."
  value       = posthog_dashboard.analytics_basics.id
}

output "insight_ids" {
  description = "Numeric IDs of the managed MVP dashboard insights keyed by HCL resource name."
  value = {
    scan_conversion_funnel     = posthog_insight.scan_conversion_funnel.id
    photos_validation_failures = posthog_insight.photos_validation_failures.id
    share_export_conversion    = posthog_insight.share_export_conversion.id
    save_to_photos_conversion  = posthog_insight.save_to_photos_conversion.id
    quota_pressure             = posthog_insight.quota_pressure.id
  }
}
