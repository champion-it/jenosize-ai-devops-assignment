variable "project_id" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "api_image" {
  type = string
}

variable "worker_image" {
  type = string
}

variable "database_url_secret_id" {
  type = string
}

variable "database_url_secret_name" {
  type = string
}

variable "min_instances" {
  description = "Set to 1 or more in prod to avoid cold starts on the first request."
  type        = number
  default     = 0
}

variable "max_instances" {
  type    = number
  default = 10
}

variable "concurrency" {
  type    = number
  default = 40
}

variable "cpu" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "512Mi"
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "embedding_provider" {
  type    = string
  default = "hashing"
}

variable "embedding_dim" {
  description = "Must match between the API and the worker; the vector column width is fixed at migration time."
  type        = number
  default     = 768
}

variable "llm_provider" {
  type    = string
  default = "mock"
}

variable "managed_prometheus" {
  description = <<-EOT
    Run an OpenTelemetry Collector sidecar that scrapes the container's
    /metrics and writes to Managed Service for Prometheus.

    Without it the Prometheus metrics this service exports exist only where
    a Prometheus is scraping it, which on Cloud Run is nowhere. The SLO
    recording rules and burn-rate alerts would then be real in
    docker-compose and absent in production, which is worse than not having
    written them.
  EOT
  type = object({
    enabled         = bool
    scrape_interval = string
    image           = string
  })
  default = {
    enabled = true
    # 30s rather than 10s: Google's own guidance is that moving from 10s to
    # 30s cuts sample volume by about two thirds, and the burn-rate windows
    # here are 5 minutes and longer, so the resolution is not needed.
    scrape_interval = "30s"
    image           = "us-docker.pkg.dev/cloud-ops-agents-artifacts/google-cloud-opentelemetry-collector/otelcol-google:0.123.0"
  }
}

variable "otel_exporter_otlp_endpoint" {
  description = <<-EOT
    OTLP endpoint for traces. Null means spans are created but not exported,
    which still gives every log line a trace id. On GCP this points at an
    OpenTelemetry Collector that forwards to Cloud Trace; the collector is
    deliberately not part of this module, so the choice of backend is not
    baked into the service.
  EOT
  type        = string
  default     = null
}

variable "otel_sample_ratio" {
  description = "1.0 traces everything. Lower it in prod once volume justifies it."
  type        = number
  default     = 1.0
}

variable "rate_limit_per_minute" {
  type    = number
  default = 60
}

variable "allow_unauthenticated" {
  type    = bool
  default = true
}

variable "internal_ingress_only" {
  type    = bool
  default = false
}

variable "reindex_schedule" {
  description = "Cron expression, or null to disable the scheduled reindex."
  type        = string
  default     = null
}
