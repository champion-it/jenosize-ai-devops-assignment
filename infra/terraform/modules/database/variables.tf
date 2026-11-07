variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups permitted to reach Postgres. Not CIDRs: a rule that names a group cannot widen when a subnet is resized."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  description = "15 or later, so pgvector is available as an extension."
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling. Prevents a runaway index from filling the disk and taking the service down."
  type        = number
  default     = 100
}

variable "database_name" {
  type    = string
  default = "jenie"
}

variable "database_user" {
  type    = string
  default = "jenie_app"
}

variable "multi_az" {
  description = "A standby in a second zone with automatic failover. Roughly doubles the cost."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Any value above zero also enables point in time recovery."
  type        = number
  default     = 7
}

variable "performance_insights" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  description = "A final snapshot is right for prod and pure friction for an environment torn down daily."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  type    = bool
  default = true
}

variable "secret_recovery_days" {
  description = "0 lets a destroyed secret name be reused immediately, which a short-lived environment needs. Secrets Manager otherwise holds the name for 7 to 30 days."
  type        = number
  default     = 0
}

variable "tags" {
  type    = map(string)
  default = {}
}
