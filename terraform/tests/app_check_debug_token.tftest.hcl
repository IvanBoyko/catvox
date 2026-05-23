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
}

run "null_token" {
  command = plan

  variables {
    app_check_debug_token = null
  }

  assert {
    condition     = length(google_firebase_app_check_debug_token.ios_dev) == 0
    error_message = "App Check debug token should not be registered when token is null."
  }
}

run "empty_token" {
  command = plan

  variables {
    app_check_debug_token = ""
  }

  assert {
    condition     = length(google_firebase_app_check_debug_token.ios_dev) == 0
    error_message = "App Check debug token should not be registered when token is empty."
  }
}

run "whitespace_token" {
  command = plan

  variables {
    app_check_debug_token = "   "
  }

  assert {
    condition     = length(google_firebase_app_check_debug_token.ios_dev) == 0
    error_message = "App Check debug token should not be registered when token is only whitespace."
  }
}

run "valid_token" {
  command = plan

  variables {
    app_check_debug_token = "00000000-0000-0000-0000-000000000001"
  }

  assert {
    condition     = length(google_firebase_app_check_debug_token.ios_dev) == 1
    error_message = "App Check debug token should be registered when token is valid."
  }

  assert {
    condition     = google_firebase_app_check_debug_token.ios_dev[0].display_name == "CatVox test App Check debug token"
    error_message = "App Check debug token display name does not match expected format."
  }
}
