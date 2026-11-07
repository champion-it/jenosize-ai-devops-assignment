variable "project_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "api_service_name" {
  type = string
}

variable "worker_job_name" {
  type = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "error_rate_threshold" {
  description = "5xx responses per second that trips the critical alert."
  type        = number
  default     = 0.5
}

variable "latency_threshold_ms" {
  type    = number
  default = 2000
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "enable_slo_alerts" {
  description = <<-EOT
    Create the burn-rate policies generated from the Prometheus rules. They
    need Managed Service for Prometheus to be receiving the metrics, which
    the service module's sidecar provides.
  EOT
  type        = bool
  default     = true
}
