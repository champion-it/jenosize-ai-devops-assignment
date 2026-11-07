# Alerting and log retention.
#
# The Prometheus rules in /observability are the source of truth for the
# service level alerts. These policies cover the platform level signals that
# Prometheus cannot see, such as the service failing to start at all.

resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.alert_emails)

  display_name = "Jenie ${var.environment} ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }
}

resource "google_monitoring_alert_policy" "high_error_rate" {
  display_name = "Jenie ${var.environment} - 5xx rate above 5 percent"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Cloud Run 5xx ratio"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "resource.labels.service_name = \"${var.api_service_name}\"",
        "metric.type = \"run.googleapis.com/request_count\"",
        "metric.labels.response_code_class = \"5xx\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_rate_threshold
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [for channel in google_monitoring_notification_channel.email : channel.id]

  documentation {
    content = join("\n", [
      "More than ${var.error_rate_threshold} errors per second on ${var.api_service_name}.",
      "",
      "1. Check which revision is serving traffic.",
      "2. If a release is in flight, shift traffic back to the previous revision.",
      "3. Compare rag_retrieval_duration_seconds and rag_answer_duration_seconds in Grafana.",
    ])
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "high_latency" {
  display_name = "Jenie ${var.environment} - p95 request latency above 2s"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Cloud Run request latency"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "resource.labels.service_name = \"${var.api_service_name}\"",
        "metric.type = \"run.googleapis.com/request_latencies\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = var.latency_threshold_ms
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_95"
      }
    }
  }

  notification_channels = [for channel in google_monitoring_notification_channel.email : channel.id]
}

# Separate bucket so audit style logs can be retained longer than the noisy
# application logs without paying for both at the same retention.
resource "google_logging_project_bucket_config" "application" {
  project        = var.project_id
  location       = var.region
  retention_days = var.log_retention_days
  bucket_id      = "jenie-${var.environment}-application"
  description    = "Application logs for the Jenie platform"
}

resource "google_logging_project_sink" "application" {
  name        = "jenie-${var.environment}-application"
  destination = "logging.googleapis.com/${google_logging_project_bucket_config.application.id}"

  filter = join(" OR ", [
    "resource.labels.service_name = \"${var.api_service_name}\"",
    "resource.labels.job_name = \"${var.worker_job_name}\"",
  ])

  unique_writer_identity = true
}

# Turns a log line into a metric so the indexer can be alerted on even though
# it is a batch job with no scrape endpoint.
resource "google_logging_metric" "indexing_failures" {
  name   = "jenie_${var.environment}_indexing_failures"
  filter = "resource.labels.job_name = \"${var.worker_job_name}\" AND severity >= ERROR"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "indexing_failed" {
  display_name = "Jenie ${var.environment} - indexing run failed"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Indexer error log entries"

    condition_threshold {
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.indexing_failures.name}\" AND resource.type = \"cloud_run_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = [for channel in google_monitoring_notification_channel.email : channel.id]

  documentation {
    content   = "The index may be stale. Rerun the job; it is idempotent and skips unchanged documents."
    mime_type = "text/markdown"
  }
}

# ---------------------------------------------------------------------------
# SLO burn-rate alerts
#
# Cloud Monitoring evaluates PromQL directly against Managed Service for
# Prometheus, so the objectives defined in docs/slo.md apply in production
# and not only in docker-compose.
#
# slo_alerts.json is generated from observability/alerts/rules.yml by
# scripts/render_slo_alerts.py, which inlines the recording rules because
# Cloud Monitoring does not evaluate them. CI re-renders and fails if the
# committed file is stale, so the YAML stays the single place a threshold is
# edited and these policies cannot drift away from it.
# ---------------------------------------------------------------------------

locals {
  slo_policies = {
    for policy in jsondecode(file("${path.module}/slo_alerts.json")).policies :
    policy.name => policy
  }
}

resource "google_monitoring_alert_policy" "slo" {
  for_each = var.enable_slo_alerts ? local.slo_policies : {}

  project      = var.project_id
  display_name = "Jenie ${var.environment} - ${each.value.summary}"
  combiner     = "OR"
  severity     = each.value.severity == "critical" ? "CRITICAL" : "WARNING"

  conditions {
    display_name = each.key

    condition_prometheus_query_language {
      query    = each.value.query
      duration = each.value.duration
      # Matches the rule group interval in rules.yml, so the two evaluate
      # the same expression at the same cadence.
      evaluation_interval = "30s"

      labels = {
        slo         = each.value.slo
        pages       = tostring(each.value.pages)
        environment = var.environment
      }
    }
  }

  notification_channels = [for channel in google_monitoring_notification_channel.email : channel.id]

  documentation {
    content = join("\n\n", compact([
      each.value.description,
      "Objectives and the error budget policy: docs/slo.md",
      each.value.pages ? "This one pages." : "Raise a ticket; this does not need waking anyone.",
    ]))
    mime_type = "text/markdown"
  }

  # A burn-rate alert that stays open after the burn stops is noise. The
  # expression already requires a short window to agree, so closing
  # automatically is safe.
  alert_strategy {
    auto_close = "1800s"
  }
}
