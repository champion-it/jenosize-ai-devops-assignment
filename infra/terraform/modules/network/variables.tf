variable "name_prefix" {
  description = "Prefix applied to every resource name, usually jenie-<env>."
  type        = string
}

variable "region" {
  type = string
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.0.0/24"
}

variable "enable_cloud_armor" {
  description = "Cloud Armor requires a load balancer in front of Cloud Run."
  type        = bool
  default     = false
}

variable "rate_limit_per_minute" {
  type    = number
  default = 120
}
