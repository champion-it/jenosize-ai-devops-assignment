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
