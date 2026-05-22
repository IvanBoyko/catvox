###############################################################################
# CatVox AI — PostHog Terraform Variables
#
# Per-environment non-secret values come from config/environments/<env>.xcconfig
# (read by the Makefile), and the PostHog API key comes from the matching
# GitHub Environment secret. There is no committed tfvars file for the PostHog
# root — see ADR-0020.
###############################################################################

variable "environment_name" {
  description = "CatVox named environment, for example dev or prod. Must match an entry in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.environment_name) > 0
    error_message = "environment_name must not be empty. Set CATVOX_ENVIRONMENT in the matching xcconfig or pass TF_VAR_environment_name."
  }
}

variable "posthog_api_host" {
  description = "PostHog API base URL for this CatVox environment. Sourced from CATVOX_POSTHOG_API_HOST_NAME in config/environments/<env>.xcconfig and composed as https://<host> by the Makefile."
  type        = string

  validation {
    condition     = startswith(var.posthog_api_host, "https://") && length(trimprefix(var.posthog_api_host, "https://")) > 0
    error_message = "posthog_api_host must be a full https:// URL composed from CATVOX_POSTHOG_API_HOST_NAME."
  }
}

variable "posthog_project_id" {
  description = "PostHog project ID for this CatVox environment. Sourced from CATVOX_POSTHOG_PROJECT_ID in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.posthog_project_id) > 0
    error_message = "posthog_project_id must not be empty. Set CATVOX_POSTHOG_PROJECT_ID in the matching xcconfig."
  }
}

variable "posthog_organization_id" {
  description = "PostHog organization UUID for this CatVox environment. Sourced from CATVOX_POSTHOG_ORGANIZATION_ID in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.posthog_organization_id) > 0
    error_message = "posthog_organization_id must not be empty. Set CATVOX_POSTHOG_ORGANIZATION_ID in the matching xcconfig."
  }
}
