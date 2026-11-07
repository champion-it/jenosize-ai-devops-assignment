variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name_prefix" {
  type    = string
  default = "jenie"
}

variable "state_bucket_name" {
  description = "Globally unique across all of S3. Suggested: jenie-tfstate-<account id>."
  type        = string
}

variable "github_repository" {
  description = "owner/name. Only workflows in this repository may assume the CI roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Must be owner/name, for example champion-it/jenosize-ai-devops-assignment-yodthong."
  }
}

variable "terraform_policy_arns" {
  description = <<-EOT
    Policies for the role that applies infrastructure. PowerUser plus
    explicit IAM is narrower than Administrator and wide enough for this
    stack. A long-lived account would replace it with an enumerated list
    once the resource set stops changing.
  EOT
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/PowerUserAccess"]
}

variable "force_delete_ecr" {
  description = "Allows terraform destroy to remove repositories that still hold images. Right for a short-lived environment, wrong for a registry anyone depends on."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "0 disables the budget. On a cluster that bills hourly, leave it on."
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  type    = list(string)
  default = []
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "jenie-helpdesk-ai"
    ManagedBy = "terraform"
  }
}
