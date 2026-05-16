###############################################################################
# CatVox AI — GCP Foundation
# Kathelix Ltd | TRD §6
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  tf_state_bucket = coalesce(var.tf_state_bucket, "catvox-tf-state-${var.project_id}")
}

# ── Project APIs ──────────────────────────────────────────────────────────────
# TRD §6.1 — enable all required GCP services.

resource "google_project_service" "apis" {
  for_each = toset([
    "aiplatform.googleapis.com",          # Vertex AI / Gemini
    "cloudfunctions.googleapis.com",      # Cloud Functions
    "cloudbuild.googleapis.com",          # Cloud Build — containerises Functions 2nd gen
    "run.googleapis.com",                 # Functions 2nd gen runs on Cloud Run
    "eventarc.googleapis.com",            # Event routing for Functions 2nd gen
    "pubsub.googleapis.com",              # Required by Eventarc
    "firestore.googleapis.com",           # Usage guard storage
    "storage.googleapis.com",             # Video uploads + Cloud Build staging bucket
    "secretmanager.googleapis.com",       # Credential management
    "firebase.googleapis.com",            # Firebase platform
    "firebaseextensions.googleapis.com",  # Firebase Functions deploy prerequisite
    "firebaseappcheck.googleapis.com",    # App Check enforcement
    "iam.googleapis.com",                 # SA + role management
    "artifactregistry.googleapis.com",    # Container images for Functions 2nd gen
    "cloudbilling.googleapis.com",        # Required by Firebase CLI for Functions deploy
    "compute.googleapis.com",             # Provisions default compute SA used by Functions 2nd gen builds
    "monitoring.googleapis.com",          # Cloud Monitoring — alerting policies + notification channels
    "clouderrorreporting.googleapis.com", # Error Reporting — groups unhandled exceptions from Cloud Run
  ])

  service            = each.value
  disable_on_destroy = false # Keep APIs enabled on terraform destroy
}

# ── Cloud Storage — Raw Video Bucket ─────────────────────────────────────────
# TRD §6.4 — transient clip hosting; delete after 24 h (privacy + cost).
#
# Bucket name appends project ID for global uniqueness — GCS names are
# world-unique. Base name matches TRD §6.4: "catvox-raw-videos".

resource "google_storage_bucket" "raw_videos" {
  name                        = "catvox-raw-videos-${var.project_id}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false # Prevent accidental data loss

  # TRD §6.4 — delete uploaded clips after 24 h (privacy + cost).
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 1 # days
    }
  }

  # TRD §6.4 — allow direct PUT uploads from the iOS client via signed URLs.
  # origin "*" is safe here because access is controlled by the signed URL
  # itself (time-limited, single-object), not by the CORS origin header.
  cors {
    origin          = ["*"]
    method          = ["PUT", "HEAD"]
    response_header = ["Content-Type", "Content-Length", "ETag"]
    max_age_seconds = 3600
  }

  depends_on = [google_project_service.apis]
}

# Vertex AI service agent — must be able to read video objects from GCS when
# processing fileData references (gs:// URIs passed to Gemini multimodal calls).
#
# google_project_service_identity explicitly provisions the Vertex AI service
# agent and exposes its email as a Terraform reference. Without this, the IAM
# binding would race against the asynchronous agent provisioning that happens
# after the API is enabled — causing failures on a fresh project.
resource "google_project_service_identity" "aiplatform" {
  provider = google-beta
  project  = var.project_id
  service  = "aiplatform.googleapis.com"

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "vertexai_sa_raw_videos_viewer" {
  bucket = google_storage_bucket.raw_videos.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_project_service_identity.aiplatform.email}"

  depends_on = [google_project_service_identity.aiplatform]
}

# ── Artifact Registry — Cloud Functions Container Images ─────────────────────
# TRD §6.1 — Cloud Functions 2nd gen builds container images and stores them
# in Artifact Registry before deploying to Cloud Run.

resource "google_artifact_registry_repository" "functions" {
  location      = var.region
  repository_id = "catvox-functions"
  format        = "DOCKER"
  description   = "Container images for CatVox Cloud Functions (2nd gen) builds."

  depends_on = [google_project_service.apis]
}

# ── Firestore — Usage Guard ───────────────────────────────────────────────────
# TRD §6.4 — collection: usage/{userId}
#             schema:     { count: integer, lastResetDate: string (YYYY-MM-DD) }
#             logic:      backend rejects with 429 when daily limit reached.

resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = var.firestore_location # See variables.tf
  type        = "FIRESTORE_NATIVE"

  depends_on = [google_project_service.apis]
}

# ── Firebase — Project + iOS App + App Check ────────────────────────────────
# ADR-0017 / ADR-0018 — each named environment owns its own Firebase project
# app, bundle ID, App Check configuration, and debug-token lifecycle.

resource "google_firebase_project" "default" {
  provider = google-beta
  project  = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_firebase_apple_app" "ios" {
  provider = google-beta
  project  = var.project_id

  display_name    = var.firebase_ios_app_display_name
  bundle_id       = var.firebase_ios_bundle_id
  team_id         = var.firebase_apple_team_id
  deletion_policy = "DELETE"

  depends_on = [google_firebase_project.default]
}

resource "google_firebase_app_check_app_attest_config" "ios" {
  provider = google-beta
  project  = var.project_id

  app_id    = google_firebase_apple_app.ios.app_id
  token_ttl = var.app_check_token_ttl

  depends_on = [google_project_service.apis]
}

resource "google_firebase_app_check_debug_token" "ios_dev" {
  provider = google-beta
  count    = var.enable_app_check_debug_token ? 1 : 0
  project  = var.project_id

  app_id       = google_firebase_apple_app.ios.app_id
  display_name = var.app_check_debug_token_display_name
  token        = var.app_check_debug_token

  lifecycle {
    precondition {
      condition     = !var.enable_app_check_debug_token || try(trimspace(var.app_check_debug_token) != "", false)
      error_message = "app_check_debug_token must be set when enable_app_check_debug_token is true."
    }
  }
}

data "google_firebase_apple_app_config" "ios" {
  provider = google-beta
  project  = var.project_id

  app_id = google_firebase_apple_app.ios.app_id
}

# ── Secret Manager ────────────────────────────────────────────────────────────
# TRD §6.1 — zero hardcoded identifiers; all resolved at Cloud Function
# startup via Secret Manager. Values are never stored in source control.

resource "google_secret_manager_secret" "gcp_project_id" {
  secret_id = "GCP_PROJECT_ID"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "gcp_project_id" {
  secret      = google_secret_manager_secret.gcp_project_id.id
  secret_data = var.project_id
}

resource "google_secret_manager_secret" "app_check_debug_token" {
  count     = var.enable_app_check_debug_token ? 1 : 0
  secret_id = "APP_CHECK_DEBUG_TOKEN"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "app_check_debug_token" {
  count       = var.enable_app_check_debug_token ? 1 : 0
  secret      = google_secret_manager_secret.app_check_debug_token[0].id
  secret_data = var.app_check_debug_token # sensitive — supplied via tfvars
}
