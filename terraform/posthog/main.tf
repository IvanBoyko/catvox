###############################################################################
# CatVox AI — PostHog Terraform Root
# Kathelix Ltd | ADR-0019, ADR-0020 | GitHub issue #37
#
# This root manages PostHog projects, dashboards, and insights for one CatVox
# environment at a time. The environment is selected at `terraform init` time
# via inline `-backend-config` arguments passed by the Makefile.
#
# State for each environment lives in the matching GCP project's state bucket
# with prefix `posthog/state`, alongside the GCP infrastructure state at
# prefix `catvox/state`. There is no separate state bucket for PostHog.
#
# This slice (issue #37 Slice 3) intentionally declares no PostHog resources.
# Credentials and project access are first exercised by Slice 4, which imports
# the existing `CatVox Dev` PostHog project. If GitHub Environment PostHog
# secrets are misconfigured, the Slice 4 plan will fail loudly with a clear
# provider error — accepting one slice of delayed credential validation
# avoided embedding a personal email (the only credential-touching data source
# the provider exposes is `posthog_user`, which requires a target email).
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    posthog = {
      source  = "PostHog/posthog"
      version = "~> 1.0"
    }
  }

  backend "gcs" {}
}

# The PostHog provider reads only operational secrets from environment
# variables. Non-secret environment identity comes from xcconfig-driven
# Terraform variables so config/environments/<env>.xcconfig remains the source
# of truth.
provider "posthog" {
  host            = var.posthog_api_host
  project_id      = var.posthog_project_id
  organization_id = var.posthog_organization_id
}
