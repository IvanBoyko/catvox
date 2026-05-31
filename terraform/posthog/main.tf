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
# The `CatVox <Environment>` project, the "Analytics basics" dashboard, the
# dashboard layout, and 5 insights are all managed declaratively from this
# root. Terraform is the source of truth: new environments are provisioned by
# `terraform apply` against fresh state, not by importing wizard-created
# resources. The original Dev import (issue #37 Slice 4) was a one-shot
# bootstrap; the `import {}` blocks were removed after first apply.
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

moved {
  from = posthog_insight.daily_scan_volume
  to   = posthog_insight.photos_validation_failures
}

moved {
  from = posthog_insight.top_cat_personas
  to   = posthog_insight.share_export_conversion
}

moved {
  from = posthog_insight.scan_share_actions
  to   = posthog_insight.save_to_photos_conversion
}

# CatVox <Environment> PostHog project. Per ADR-0019/ADR-0020 each environment
# manages its own project; this state targets exactly one environment, selected
# at init time. The display name follows the `CatVox <Environment>` convention
# from ADR-0019 so the same definition covers every environment unchanged.
resource "posthog_project" "this" {
  organization_id = var.posthog_organization_id
  name            = "CatVox ${title(var.environment_name)}"
  timezone        = "UTC"
}
