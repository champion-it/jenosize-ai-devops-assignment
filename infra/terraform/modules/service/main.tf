# Cloud Run service (API) and Cloud Run job (indexer).
#
# Each workload gets its own service account holding only the permissions it
# needs. The API never gains the ability to write images, and the indexer is
# never reachable from the internet.

resource "google_service_account" "api" {
  account_id   = "${var.name_prefix}-api"
  display_name = "Jenie API (${var.environment})"
}

resource "google_service_account" "worker" {
  account_id   = "${var.name_prefix}-worker"
  display_name = "Jenie indexer (${var.environment})"
}

# Read access to one secret, not to the project's secrets.
resource "google_secret_manager_secret_iam_member" "api_database_url" {
  secret_id = var.database_url_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_database_url" {
  secret_id = var.database_url_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "worker_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "api_metrics_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloud_run_v2_service" "api" {
  name     = "${var.name_prefix}-api"
  location = var.region

  # Prod sits behind a load balancer with Cloud Armor; dev is reachable
  # directly so the pipeline can smoke test it.
  ingress = var.internal_ingress_only ? "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" : "INGRESS_TRAFFIC_ALL"

  deletion_protection = false

  template {
    service_account = google_service_account.api.email

    dynamic "volumes" {
      for_each = var.managed_prometheus.enabled ? [1] : []
      content {
        name = "otel-config"
        secret {
          secret = google_secret_manager_secret.otel_config[0].secret_id
          items {
            version = "latest"
            path    = "config.yaml"
          }
        }
      }
    }

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Direct VPC egress reaches the private Cloud SQL IP without a connector.
    vpc_access {
      network_interfaces {
        network    = var.network_name
        subnetwork = var.subnet_name
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    max_instance_request_concurrency = var.concurrency

    containers {
      image = var.api_image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle = var.min_instances == 0
      }

      ports {
        container_port = 8000
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      env {
        name  = "LOG_LEVEL"
        value = var.log_level
      }

      env {
        name  = "EMBEDDING_PROVIDER"
        value = var.embedding_provider
      }

      env {
        name  = "EMBEDDING_DIM"
        value = tostring(var.embedding_dim)
      }

      env {
        name  = "LLM_PROVIDER"
        value = var.llm_provider
      }

      dynamic "env" {
        for_each = var.otel_exporter_otlp_endpoint == null ? [] : [1]
        content {
          name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
          value = var.otel_exporter_otlp_endpoint
        }
      }

      env {
        name  = "OTEL_SAMPLE_RATIO"
        value = tostring(var.otel_sample_ratio)
      }

      env {
        name  = "RATE_LIMIT_PER_MINUTE"
        value = tostring(var.rate_limit_per_minute)
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = var.database_url_secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        http_get {
          path = "/readyz"
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 10
      }

      dynamic "volume_mounts" {
        for_each = var.managed_prometheus.enabled ? [1] : []
        content {
          name       = "otel-config"
          mount_path = "/etc/otel"
        }
      }

      liveness_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 30
        failure_threshold = 3
      }
    }

    # Scrapes 127.0.0.1:8000/metrics inside the same instance and writes to
    # Managed Service for Prometheus. The metric names are unchanged, so the
    # recording rules and burn-rate alerts in observability/alerts/rules.yml
    # describe the same series here as they do in docker-compose.
    dynamic "containers" {
      for_each = var.managed_prometheus.enabled ? [1] : []
      content {
        name    = "otel-sidecar"
        image   = var.managed_prometheus.image
        command = ["/otelcol-google"]
        args    = ["--config=/etc/otel/config.yaml"]

        volume_mounts {
          name       = "otel-config"
          mount_path = "/etc/otel"
        }

        resources {
          limits = {
            cpu    = "0.5"
            memory = "256Mi"
          }
        }

        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = var.project_id
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    # The deploy pipeline owns image and traffic. Terraform owns the shape of
    # the service. Without this, a terraform apply would silently roll the
    # service back to the image recorded in state.
    ignore_changes = [
      template[0].containers[0].image,
      traffic,
    ]
  }
}

resource "google_cloud_run_v2_job" "worker" {
  name     = "${var.name_prefix}-worker"
  location = var.region

  deletion_protection = false

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.worker.email
      max_retries     = 2
      timeout         = "1800s"

      vpc_access {
        network_interfaces {
          network    = var.network_name
          subnetwork = var.subnet_name
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image = var.worker_image

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        env {
          name  = "ENVIRONMENT"
          value = var.environment
        }

        env {
          name  = "EMBEDDING_PROVIDER"
          value = var.embedding_provider
        }

        env {
          name  = "EMBEDDING_DIM"
          value = tostring(var.embedding_dim)
        }

        dynamic "env" {
          for_each = var.otel_exporter_otlp_endpoint == null ? [] : [1]
          content {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = var.otel_exporter_otlp_endpoint
          }
        }

        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = var.database_url_secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image]
  }
}

# Public access is granted explicitly rather than inherited, and only where
# the environment is meant to be reachable.
resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.allow_unauthenticated ? 1 : 0
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Rebuild the index on a schedule so a document change is picked up without a
# manual run. The job is idempotent, so a rerun is cheap.
resource "google_cloud_scheduler_job" "reindex" {
  count       = var.reindex_schedule == null ? 0 : 1
  name        = "${var.name_prefix}-reindex"
  schedule    = var.reindex_schedule
  time_zone   = "Asia/Bangkok"
  region      = var.region
  description = "Periodic reindex of the knowledge base"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.worker.name}:run"

    oauth_token {
      service_account_email = google_service_account.worker.email
    }
  }
}

resource "google_project_iam_member" "worker_job_runner" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.worker.email}"
}

# OpenTelemetry Collector configuration for the metrics sidecar.
#
# It scrapes the application container over loopback inside the same Cloud
# Run instance and writes to Managed Service for Prometheus. Nothing is
# exposed on the network: the application's /metrics is not reachable from
# outside the instance.
#
# Not a secret, but Cloud Run mounts files from Secret Manager, so this is
# the mechanism available for getting a config file into a stock image
# without building one.
resource "google_secret_manager_secret" "otel_config" {
  count = var.managed_prometheus.enabled ? 1 : 0

  secret_id = "${var.name_prefix}-otel-config"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "otel_config" {
  count = var.managed_prometheus.enabled ? 1 : 0

  secret = google_secret_manager_secret.otel_config[0].id
  secret_data = yamlencode({
    receivers = {
      prometheus = {
        config = {
          scrape_configs = [{
            job_name        = "jenie-api"
            scrape_interval = var.managed_prometheus.scrape_interval
            metrics_path    = "/metrics"
            static_configs  = [{ targets = ["127.0.0.1:8000"] }]
          }]
        }
      }
    }
    processors = {
      # Required by the exporter: it needs the resource attributes that
      # identify which Cloud Run revision the sample came from.
      resourcedetection = {
        detectors = ["env", "gcp"]
        timeout   = "10s"
      }
      batch = {
        send_batch_max_size = 200
        send_batch_size     = 200
        timeout             = "5s"
      }
    }
    exporters = {
      googlemanagedprometheus = {
        project = var.project_id
      }
    }
    service = {
      pipelines = {
        metrics = {
          receivers  = ["prometheus"]
          processors = ["resourcedetection", "batch"]
          exporters  = ["googlemanagedprometheus"]
        }
      }
    }
  })
}

# The API service account reads the config, and writes the samples.
resource "google_secret_manager_secret_iam_member" "otel_config" {
  count = var.managed_prometheus.enabled ? 1 : 0

  secret_id = google_secret_manager_secret.otel_config[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}
