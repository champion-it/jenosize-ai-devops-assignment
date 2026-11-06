variable "project_id" {
  description = "Target GCP project. Bootstrap does not create the project."
  type        = string
}

variable "project_number" {
  description = "Numeric project number, used by the budget filter."
  type        = string
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "state_bucket_name" {
  description = "Globally unique. Suggested: <project_id>-tfstate."
  type        = string
}

variable "github_repository" {
  description = "owner/name. Only workflows in this repository may federate."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Must be owner/name, for example champion-it/jenosize-ai-devops-assignment."
  }
}

variable "deploy_roles" {
  description = "Roles for the pipeline that builds images and deploys revisions."
  type        = list(string)
  default = [
    "roles/artifactregistry.writer",
    "roles/run.admin",
    # Required to deploy a revision that runs as the workload service account.
    "roles/iam.serviceAccountUser",
  ]
}

variable "terraform_roles" {
  description = <<-EOT
    Roles for the account that applies infrastructure. Broader than the
    deploy account by necessity, which is why they are separate identities.
    roles/editor is avoided on purpose: it grants data access this account
    never needs.
  EOT
  type        = list(string)
  default = [
    "roles/artifactregistry.admin",
    "roles/cloudscheduler.admin",
    "roles/cloudsql.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/logging.admin",
    "roles/monitoring.editor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/servicenetworking.networksAdmin",
  ]
}

variable "billing_account" {
  description = "Billing account id. Leave null to skip the budget."
  type        = string
  default     = null
}

variable "monthly_budget" {
  description = "Budget amount per month, in budget_currency."
  type        = number
  default     = 50
}

variable "budget_currency" {
  type    = string
  default = "USD"
}
