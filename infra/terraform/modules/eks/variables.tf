variable "name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "public_access_cidrs" {
  description = <<-EOT
    Who may reach the control plane endpoint. Defaults to open because CI
    runners have no fixed egress address; narrow it to an office or VPN
    range wherever that is possible.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "fargate_namespaces" {
  description = <<-EOT
    Namespaces whose pods run on Fargate. A namespace without a profile
    schedules nothing at all, so this list is effectively the set of
    namespaces the cluster serves.
  EOT
  type        = list(string)
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "region" {
  description = "Used only to render the update-kubeconfig hint."
  type        = string
}
