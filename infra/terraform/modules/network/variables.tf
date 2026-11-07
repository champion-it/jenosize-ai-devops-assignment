variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type = list(string)
}

variable "az_count" {
  description = "EKS requires subnets in at least two zones."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "EKS needs at least two availability zones."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    One NAT gateway for the whole VPC instead of one per zone. Saves about
    $32 a month per zone and makes that gateway a single point of failure
    for outbound traffic. True is the right answer while cost matters more
    than zone-level resilience; it is a variable so the trade is visible.
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

variable "flow_log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
