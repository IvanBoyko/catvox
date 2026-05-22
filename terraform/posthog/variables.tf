###############################################################################
# CatVox AI — PostHog Terraform Variables
#
# Per-environment values come from config/environments/<env>.xcconfig (read by
# the Makefile) and per-environment GitHub Environment secrets/variables (read
# by the CI workflow). There is no committed tfvars file for the PostHog root
# — see ADR-0020.
###############################################################################

variable "environment_name" {
  description = "CatVox named environment, for example dev or prod. Must match an entry in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.environment_name) > 0
    error_message = "environment_name must not be empty. Set CATVOX_ENVIRONMENT in the matching xcconfig or pass TF_VAR_environment_name."
  }
}

variable "posthog_project_id" {
  description = "PostHog project ID for this CatVox environment. Sourced from CATVOX_POSTHOG_PROJECT_ID in config/environments/<env>.xcconfig locally, or from the matching GitHub Environment variable in CI."
  type        = string

  validation {
    condition     = length(var.posthog_project_id) > 0
    error_message = "posthog_project_id must not be empty. Set CATVOX_POSTHOG_PROJECT_ID in the matching xcconfig or pass TF_VAR_posthog_project_id."
  }
}
