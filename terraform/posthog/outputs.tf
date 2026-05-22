###############################################################################
# CatVox AI — PostHog Terraform Outputs
#
# Slice 3 scope: the root declares no PostHog resources yet, so it only
# surfaces the environment identity it was initialised for. Slice 4 and Slice 5
# of issue #37 will add outputs for the imported project, dashboards, and
# insights.
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
