variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

variable "private_service_connection" {
  description = "Forces ordering behind the VPC peering connection."
  type        = string
}

variable "tier" {
  type    = string
  default = "db-custom-1-3840"
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "highly_available" {
  description = "REGIONAL gives a standby in a second zone with automatic failover."
  type        = bool
  default     = false
}

variable "point_in_time_recovery" {
  type    = bool
  default = false
}

variable "retained_backups" {
  type    = number
  default = 7
}

variable "backup_location" {
  description = "Set to a different region than the instance for DR."
  type        = string
  default     = "asia"
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "database_name" {
  type    = string
  default = "jenie"
}

variable "database_user" {
  type    = string
  default = "jenie_app"
}
