variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "single_nat_gateway" {
  description = "One NAT gateway instead of one per zone. Saves about 32 USD a month per zone at the cost of zone-level resilience for outbound traffic."
  type        = bool
  default     = true
}

variable "cluster_public_access_cidrs" {
  description = "Who may reach the control plane. Narrow this to an office or VPN range where that is possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "database_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "alert_emails" {
  description = "Subscribed to the SNS topic Alertmanager publishes to. Each address must confirm the subscription by email before it receives anything."
  type        = list(string)
  default     = []
}

variable "lb_controller_chart_version" {
  type    = string
  default = "1.10.1"
}

variable "argo_rollouts_chart_version" {
  type    = string
  default = "2.38.0"
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "jenie-helpdesk-ai"
    ManagedBy = "terraform"
  }
}
