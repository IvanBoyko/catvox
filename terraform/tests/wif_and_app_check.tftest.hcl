# Focused coverage for the per-environment security boundaries introduced in
# issue #38 Step 3: environment+ref-scoped WIF trust (ADR-0024) and Firestore
# App Check enforcement (ADR-0025). Both are pure config-derived values, so a
# mocked `plan` is sufficient and no live GCP access is needed.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  environment_name                 = "test"
  project_id                       = "test-project"
  region                           = "us-central1"
  firestore_location               = "nam5"
  tf_state_bucket                  = "test-bucket"
  firebase_ios_bundle_id           = "com.test.app"
  firebase_ios_app_display_name    = "Test App"
  firebase_ios_app_deletion_policy = "DELETE"
  firebase_apple_team_id           = "TEAMID"
  alert_email                      = "test@test.com"
  manage_gcf_sources_bucket_iam    = "false"
  firestore_app_check_enforcement  = "UNENFORCED"
}

run "wif_condition_env_scoped_without_ref" {
  command = plan

  variables {
    github_ref = ""
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github_actions.attribute_condition == "assertion.repository == 'kathelix/catvox' && assertion.environment == 'test'"
    error_message = "WIF attribute_condition must require repository and environment when no ref is pinned."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github_actions.attribute_mapping["attribute.environment"] == "assertion.environment"
    error_message = "WIF attribute_mapping must expose attribute.environment from assertion.environment."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github_actions.attribute_mapping["attribute.ref"] == "assertion.ref"
    error_message = "WIF attribute_mapping must expose attribute.ref from assertion.ref."
  }

  assert {
    condition     = endswith(google_service_account_iam_member.ci_sa_wif_binding.member, "/attribute.environment/test")
    error_message = "CI SA WIF binding principalSet must be scoped to attribute.environment/<environment_name>."
  }
}

run "wif_condition_env_and_ref_scoped" {
  command = plan

  variables {
    github_ref = "refs/heads/main"
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github_actions.attribute_condition == "assertion.repository == 'kathelix/catvox' && assertion.environment == 'test' && assertion.ref == 'refs/heads/main'"
    error_message = "WIF attribute_condition must additionally require assertion.ref when github_ref is set."
  }
}

run "wif_condition_trims_ref_whitespace" {
  command = plan

  variables {
    github_ref = "  refs/heads/main  "
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github_actions.attribute_condition == "assertion.repository == 'kathelix/catvox' && assertion.environment == 'test' && assertion.ref == 'refs/heads/main'"
    error_message = "github_ref must be trimmed before being embedded in the attribute_condition."
  }
}

run "firestore_app_check_enforced" {
  command = plan

  variables {
    firestore_app_check_enforcement = "ENFORCED"
  }

  assert {
    condition     = google_firebase_app_check_service_config.firestore.enforcement_mode == "ENFORCED"
    error_message = "Firestore App Check service config must use the configured enforcement_mode."
  }

  assert {
    condition     = google_firebase_app_check_service_config.firestore.service_id == "firestore.googleapis.com"
    error_message = "App Check service config must target firestore.googleapis.com."
  }
}

run "firestore_app_check_unenforced" {
  command = plan

  variables {
    firestore_app_check_enforcement = "UNENFORCED"
  }

  assert {
    condition     = google_firebase_app_check_service_config.firestore.enforcement_mode == "UNENFORCED"
    error_message = "Firestore App Check enforcement_mode must follow the variable (UNENFORCED for Dev)."
  }
}

run "firestore_app_check_rejects_invalid_mode" {
  command = plan

  variables {
    firestore_app_check_enforcement = "on"
  }

  expect_failures = [
    var.firestore_app_check_enforcement,
  ]
}
