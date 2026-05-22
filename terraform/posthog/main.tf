###############################################################################
# CatVox AI — PostHog Terraform Root
# Kathelix Ltd | ADR-0019, ADR-0020 | GitHub issue #37
#
# This root manages PostHog projects, dashboards, and insights for one CatVox
# environment at a time. The environment is selected at `terraform init` time
# via the backend HCL file (see backend/<env>.hcl).
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

# Provider configuration is intentionally empty. The PostHog provider reads
# POSTHOG_API_KEY, POSTHOG_HOST, POSTHOG_ORGANIZATION_ID, and POSTHOG_PROJECT_ID
# from environment variables. Local runs source these via the Makefile target;
# CI runs source them from the per-environment GitHub Environment.
provider "posthog" {}
