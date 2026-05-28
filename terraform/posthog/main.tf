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
# Slice 4 of issue #37 brings the existing `CatVox Dev` PostHog project, its
# wizard-created "Analytics basics" dashboard, and its 5 wizard insights under
# Terraform management via import {} blocks. Resource definitions for the
# dashboard, dashboard layout, and insights live in dashboard.tf and
# insights.tf alongside their import blocks.
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

# CatVox <Environment> PostHog project. Per ADR-0019/ADR-0020 each environment
# manages its own project; this state targets exactly one environment, selected
# at init time. The display name follows the `CatVox <Environment>` convention
# from ADR-0019 so future Prod replay reuses this definition unchanged.
resource "posthog_project" "this" {
  name     = "CatVox ${title(var.environment_name)}"
  timezone = "UTC"
}

import {
  to = posthog_project.this
  id = "${var.posthog_organization_id}/${var.posthog_project_id}"
}
