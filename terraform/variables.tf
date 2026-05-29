###############################################################################
# CatVox AI — Terraform Variables
# Non-secret per-environment values are sourced from
# config/environments/<environment>.xcconfig by the Makefile and passed as
# TF_VAR_* values. terraform/env/<environment>.tfvars is ignored and holds only
# true secrets such as app_check_debug_token and alert_email.
###############################################################################

variable "environment_name" {
  description = "CatVox named environment, for example dev, staging, or prod. Sourced from CATVOX_ENVIRONMENT."
  type        = string

  validation {
    condition     = length(var.environment_name) > 0
    error_message = "environment_name must not be empty. Set CATVOX_ENVIRONMENT in the matching xcconfig or pass TF_VAR_environment_name."
  }
}

variable "project_id" {
  description = "GCP/Firebase project ID for this CatVox environment. Sourced from CATVOX_PROJECT_ID in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty. Set CATVOX_PROJECT_ID in the matching xcconfig."
  }
}

variable "region" {
  description = "Primary GCP region for compute and storage resources. Sourced from CATVOX_FUNCTION_REGION in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.region) > 0
    error_message = "region must not be empty. Set CATVOX_FUNCTION_REGION in the matching xcconfig."
  }
}

variable "firestore_location" {
  description = <<-EOT
    Firestore location ID. Must be set at database creation time and cannot
    be changed afterwards. Use a multi-region ID for high availability:
      nam5  — North America (Iowa + South Carolina)  ← default
      eur3  — Europe (Belgium + Netherlands)
    Or a single-region ID (e.g. us-central1) for lower latency at the cost
    of redundancy.
    Sourced from CATVOX_FIRESTORE_LOCATION in config/environments/<env>.xcconfig.
  EOT
  type        = string

  validation {
    condition     = length(var.firestore_location) > 0
    error_message = "firestore_location must not be empty. Set CATVOX_FIRESTORE_LOCATION in the matching xcconfig."
  }
}

variable "app_check_debug_token" {
  description = <<-EOT
    Firebase App Check debug token for local development and mutable integration tests.
    Mark as sensitive — never commit the value to source control.
    Generate a UUID4 locally and store it in the environment tfvars / GitHub secret.
    Optional. Its presence dictates whether the debug token is registered.
  EOT
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
}



variable "app_check_token_ttl" {
  description = "Firebase App Check App Attest token TTL."
  type        = string
  default     = "3600s"
}

variable "firestore_app_check_enforcement" {
  description = <<-EOT
    App Check enforcement mode for Cloud Firestore in this environment.
    ENFORCED rejects Firebase client SDK requests without a valid App Check
    token; service-account / Admin SDK access (catvox-backend-sa, CI probes via
    @google-cloud/firestore) bypasses App Check and is unaffected. The value for
    each environment is set in config/environments/<env>.xcconfig as
    CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT. See ADR-0025.
  EOT
  type        = string

  validation {
    condition     = contains(["OFF", "UNENFORCED", "ENFORCED"], var.firestore_app_check_enforcement)
    error_message = "firestore_app_check_enforcement must be OFF, UNENFORCED, or ENFORCED. Set CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT in the matching xcconfig."
  }
}

variable "firebase_ios_bundle_id" {
  description = "Firebase iOS app bundle ID for this environment. Sourced from CATVOX_IOS_BUNDLE_ID in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.firebase_ios_bundle_id) > 0
    error_message = "firebase_ios_bundle_id must not be empty. Set CATVOX_IOS_BUNDLE_ID in the matching xcconfig."
  }
}

variable "firebase_ios_app_display_name" {
  description = "Firebase iOS app display name for this environment. Sourced from CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.firebase_ios_app_display_name) > 0
    error_message = "firebase_ios_app_display_name must not be empty. Set CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME in the matching xcconfig."
  }
}

variable "firebase_ios_app_deletion_policy" {
  description = "Terraform deletion policy for the Firebase iOS app. Sourced from CATVOX_FIREBASE_IOS_APP_DELETION_POLICY in config/environments/<env>.xcconfig. Use ABANDON for Prod-like environments so destroy/refactor cannot delete the App Store-registered app."
  type        = string

  validation {
    condition     = contains(["ABANDON", "DELETE"], var.firebase_ios_app_deletion_policy)
    error_message = "firebase_ios_app_deletion_policy must be ABANDON or DELETE. Set CATVOX_FIREBASE_IOS_APP_DELETION_POLICY in the matching xcconfig."
  }
}

variable "firebase_apple_team_id" {
  description = "Apple Developer Team ID associated with the Firebase iOS app. Sourced from CATVOX_FIREBASE_APPLE_TEAM_ID in config/environments/<env>.xcconfig."
  type        = string

  validation {
    condition     = length(var.firebase_apple_team_id) > 0
    error_message = "firebase_apple_team_id must not be empty. Set CATVOX_FIREBASE_APPLE_TEAM_ID in the matching xcconfig."
  }
}

variable "wif_pool_id" {
  description = "Workload Identity Federation pool ID used by GitHub Actions."
  type        = string
  default     = "github-actions-pool"
}

variable "wif_provider_id" {
  description = "Workload Identity Federation provider ID used by GitHub Actions."
  type        = string
  default     = "github-actions-provider"
}

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' format, used to scope the WIF token binding on catvox-ci-sa."
  type        = string
  default     = "kathelix/catvox"
}

variable "github_ref" {
  description = <<-EOT
    Optional Git ref the WIF provider trusts, for example refs/heads/main.
    When non-empty, the provider attribute_condition additionally requires
    assertion.ref to equal this value, restricting CI auth to that branch/tag.
    Leave empty to trust any ref for this environment. The value for each
    environment is set in config/environments/<env>.xcconfig as
    CATVOX_GCP_WIF_GITHUB_REF. See ADR-0024.
  EOT
  type        = string
  default     = ""
}

variable "tf_state_bucket" {
  description = "GCS bucket name for Terraform remote state. Created before first terraform init. Derived by the Makefile from CATVOX_TF_STATE_BUCKET or CATVOX_PROJECT_ID in config/environments/<env>.xcconfig."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.tf_state_bucket == null || length(var.tf_state_bucket) > 0
    error_message = "tf_state_bucket must be null or non-empty. Set CATVOX_TF_STATE_BUCKET in the matching xcconfig or let the Makefile derive it from CATVOX_PROJECT_ID."
  }
}

variable "alert_email" {
  description = "Email address to receive Cloud Monitoring alerts when a Cloud Function emits an ERROR-level log entry."
  type        = string
}

variable "manage_gcf_sources_bucket_iam" {
  description = "Whether Terraform should manage IAM on the Cloud Functions v2 source bucket. Sourced from CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM in config/environments/<env>.xcconfig as true or false. Environment bootstrap creates the bucket before first apply."
  type        = string

  validation {
    condition     = contains(["true", "false"], lower(trimspace(var.manage_gcf_sources_bucket_iam)))
    error_message = "manage_gcf_sources_bucket_iam must be true or false. Set CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM in the matching xcconfig."
  }
}
