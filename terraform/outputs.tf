###############################################################################
# CatVox AI — Terraform Outputs
# Values referenced when configuring Cloud Functions and the iOS build.
###############################################################################

output "backend_sa_email" {
  description = "Service account email — set as the Cloud Functions runtime SA."
  value       = google_service_account.backend_sa.email
}

output "raw_videos_bucket_name" {
  description = "GCS bucket name for transient video uploads."
  value       = google_storage_bucket.raw_videos.name
}

output "raw_videos_bucket_url" {
  description = "GCS URI prefix used in Vertex AI fileData references."
  value       = "gs://${google_storage_bucket.raw_videos.name}"
}

output "artifact_registry_url" {
  description = "Docker registry URL — used in Cloud Functions deploy commands."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/catvox-functions"
}

output "firestore_database_name" {
  description = "Firestore database name — always '(default)' for the primary database."
  value       = google_firestore_database.default.name
}

output "gcp_project_id_secret_id" {
  description = "Secret Manager secret ID for GCP_PROJECT_ID."
  value       = google_secret_manager_secret.gcp_project_id.secret_id
}

output "app_check_debug_token_secret_id" {
  description = "Secret Manager secret ID for APP_CHECK_DEBUG_TOKEN."
  value       = try(google_secret_manager_secret.app_check_debug_token[0].secret_id, null)
}

output "firebase_ios_app_id" {
  description = "Firebase iOS app ID for this environment."
  value       = google_firebase_apple_app.ios.app_id
}

output "firebase_ios_api_key_id" {
  description = "Firebase API key ID associated with the iOS app."
  value       = google_firebase_apple_app.ios.api_key_id
}

output "firebase_ios_plist_base64" {
  description = "Base64-encoded GoogleService-Info plist for the environment iOS app."
  value       = data.google_firebase_apple_app_config.ios.config_file_contents
  sensitive   = true
}

output "terraform_state_bucket_name" {
  description = "Terraform remote state bucket for this environment."
  value       = local.tf_state_bucket
}

output "github_actions_wif_provider" {
  description = "Workload Identity Federation provider resource for GitHub Actions."
  value       = "projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.wif_pool_id}/providers/${var.wif_provider_id}"
}

output "ci_service_account_email" {
  description = "GitHub Actions CI service account email."
  value       = google_service_account.ci_sa.email
}
