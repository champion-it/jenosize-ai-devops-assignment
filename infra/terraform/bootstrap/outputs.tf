# These are the values to set as GitHub repository variables. Settings ->
# Secrets and variables -> Actions -> Variables. None of them is a secret:
# federation means there is no key to store.

output "github_repository_variables" {
  description = "Copy these into the repository's Actions variables."
  value = {
    GCP_PROJECT_ID                = var.project_id
    GCP_REGION                    = var.region
    GCP_WIF_PROVIDER              = google_iam_workload_identity_pool_provider.github.name
    GCP_DEPLOY_SERVICE_ACCOUNT    = google_service_account.deploy.email
    GCP_TERRAFORM_SERVICE_ACCOUNT = google_service_account.terraform.email
    GCP_TFSTATE_BUCKET            = google_storage_bucket.state.name
  }
}

output "artifact_registry" {
  description = "Docker registry host and repository path."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.jenie.repository_id}"
}

output "state_bucket" {
  value = google_storage_bucket.state.name
}
