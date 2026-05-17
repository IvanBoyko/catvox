###############################################################################
# CatVox AI — Terraform Variables
# Populate values in terraform/env/<environment>.tfvars (never commit it).
###############################################################################

variable "environment_name" {
  description = "CatVox named environment, for example dev, staging, or prod."
  type        = string
  default     = "dev"
}

variable "project_id" {
  description = "GCP project ID for this CatVox environment."
  type        = string
}

variable "region" {
  description = "Primary GCP region for compute and storage resources."
  type        = string
  default     = "us-central1"
}

variable "firestore_location" {
  description = <<-EOT
    Firestore location ID. Must be set at database creation time and cannot
    be changed afterwards. Use a multi-region ID for high availability:
      nam5  — North America (Iowa + South Carolina)  ← default
      eur3  — Europe (Belgium + Netherlands)
    Or a single-region ID (e.g. us-central1) for lower latency at the cost
    of redundancy.
  EOT
  type        = string
  default     = "nam5"
}

variable "app_check_debug_token" {
  description = <<-EOT
    Firebase App Check debug token for local development and mutable integration tests.
    Mark as sensitive — never commit the value to source control.
    Generate a UUID4 locally and store it in the environment tfvars / GitHub secret.
    Required only when enable_app_check_debug_token is true.
  EOT
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
}

variable "enable_app_check_debug_token" {
  description = "Whether to register app_check_debug_token for this environment's Firebase iOS app. Dev-like mutable environments opt in; Prod should use false."
  type        = bool
  default     = false
}

variable "app_check_debug_token_display_name" {
  description = "Display name for the Firebase App Check debug token registered by Terraform."
  type        = string
  default     = "CatVox Dev integration token"
}

variable "app_check_token_ttl" {
  description = "Firebase App Check App Attest token TTL."
  type        = string
  default     = "3600s"
}

variable "firebase_ios_bundle_id" {
  description = "Firebase iOS app bundle ID for this environment."
  type        = string
}

variable "firebase_ios_app_display_name" {
  description = "Firebase iOS app display name for this environment."
  type        = string
  default     = "CatVox iOS"
}

variable "firebase_ios_app_deletion_policy" {
  description = "Terraform deletion policy for the Firebase iOS app. Use ABANDON for Prod-like environments so destroy/refactor cannot delete the App Store-registered app."
  type        = string
  default     = "ABANDON"

  validation {
    condition     = contains(["ABANDON", "DELETE"], var.firebase_ios_app_deletion_policy)
    error_message = "firebase_ios_app_deletion_policy must be ABANDON or DELETE."
  }
}

variable "firebase_apple_team_id" {
  description = "Apple Developer Team ID associated with the Firebase iOS app."
  type        = string
  default     = "QYT76L5836"
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

variable "tf_state_bucket" {
  description = "GCS bucket name for Terraform remote state. Created by bootstrap_remote_state.sh before first terraform init. Defaults to catvox-tf-state-<project_id>."
  type        = string
  default     = null
  nullable    = true
}

variable "alert_email" {
  description = "Email address to receive Cloud Monitoring alerts when a Cloud Function emits an ERROR-level log entry."
  type        = string
}

variable "manage_gcf_sources_bucket_iam" {
  description = "Whether Terraform should manage IAM on the Cloud Functions v2 source bucket. Environment bootstrap creates the bucket before first apply."
  type        = bool
  default     = false
}
