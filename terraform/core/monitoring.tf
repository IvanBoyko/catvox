###############################################################################
# CatVox AI — Cloud Monitoring: Error Alerting
# Sends an email when any Cloud Function emits an ERROR-level log entry.
# See docs/DEBUG.md §4 Option A for context.
###############################################################################

# Email notification channel — the address that receives alert emails.
# Value comes from var.alert_email (selected terraform/core/env/<environment>.tfvars
# locally, or GitHub Environment secrets in CI; never committed with real data).
resource "google_monitoring_notification_channel" "error_email" {
  display_name = "CatVox Error Alerts — Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.apis]
}

# Alert policy — fires on any ERROR-severity log entry from either Cloud
# Function. Uses a log-match condition directly (no separate log-based metric
# resource required). Rate-limited to one notification per 5 minutes so a
# burst of failures produces a single actionable alert, not a flood.
resource "google_monitoring_alert_policy" "function_errors" {
  display_name = "CatVox — backend function error"
  combiner     = "OR"

  conditions {
    display_name = "ERROR log entry in CatVox Cloud Functions"

    condition_matched_log {
      filter = <<-EOT
        resource.type="cloud_run_revision"
        (resource.labels.service_name="getsigneduploadurl" OR resource.labels.service_name="analysevideo")
        severity=ERROR
      EOT
    }
  }

  notification_channels = [google_monitoring_notification_channel.error_email.name]

  alert_strategy {
    # Suppress repeat notifications for the same wave of errors.
    notification_rate_limit {
      period = "300s"
    }
    # Auto-close the incident after 7 days if no further matching entries appear.
    auto_close = "604800s"
  }

  documentation {
    content   = "An ERROR-level log entry was emitted by a CatVox Cloud Function.\n\nSee `docs/DEBUG.md` for the full triage workflow, gcloud commands, and known error signatures."
    mime_type = "text/markdown"
  }

  depends_on = [google_project_service.apis]
}
