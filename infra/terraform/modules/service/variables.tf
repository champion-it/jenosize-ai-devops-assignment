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
