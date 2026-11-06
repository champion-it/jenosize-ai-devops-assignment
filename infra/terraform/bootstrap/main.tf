# Bootstrap.
#
# The things that have to exist before envs/dev or envs/prod can be applied,
# and that are created once and then left alone: enabled APIs, the state
# bucket, the image registry, and the federation that lets GitHub Actions
# authenticate without a key.
#
# It is separate from the environments for two reasons. It needs broader
# permissions than a day-to-day apply, so keeping it apart means the
# pipeline's service account never needs them. And it owns the state bucket
# the environments use, which a configuration cannot do for itself: this one
# keeps its state locally and that state is committed nowhere.

locals {
  # Enabling a service is idempotent, and ordering matters: several resources
  # below fail with a bare "API not enabled" until these are on.
  services = [
    "artifactregistry.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  # Leaving an API enabled on destroy is deliberate. Disabling one can break
  # unrelated resources in the same project that happen to depend on it.
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Terraform state
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "state" {
  name     = var.state_bucket_name
  location = var.region
  project  = var.project_id

  # Object versioning is the recovery path for corrupted state: restore the
  # previous generation of the object.
  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # State is small; keeping every version forever is not useful, but keeping
  # a generous history is. These only ever remove superseded versions.
  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 180
    }
    action {
      type = "Delete"
    }
  }

  # A bucket holding state should not be destroyable by a stray apply.
  force_destroy = false

  depends_on = [google_project_service.enabled]
}

# ---------------------------------------------------------------------------
# Image registry
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "jenie" {
  repository_id = "jenie"
  location      = var.region
  project       = var.project_id
  format        = "DOCKER"
  description   = "Jenie Helpdesk AI service images"

  docker_config {
    immutable_tags = false
  }

  # Untagged layers accumulate on every rebuild and are pure cost. Tagged
  # images are kept so a rollback target is always present.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }

  depends_on = [google_project_service.enabled]
}

# ---------------------------------------------------------------------------
# Workload Identity Federation for GitHub Actions
# ---------------------------------------------------------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "Federated identity for CI, so no service account key exists"
  project                   = var.project_id

  depends_on = [google_project_service.enabled]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"
  project                            = var.project_id

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Without this condition the provider trusts every repository on GitHub,
  # and any workflow anywhere could mint a token for this project. Scoping it
  # to one repository is the control that makes federation safe.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ---------------------------------------------------------------------------
# Service accounts used by CI
# ---------------------------------------------------------------------------

# Builds and deploys. Narrow: it may push images and manage Cloud Run, and
# nothing else.
resource "google_service_account" "deploy" {
  account_id   = "jenie-deploy"
  display_name = "Jenie deploy pipeline"
  project      = var.project_id

  depends_on = [google_project_service.enabled]
}

# Applies infrastructure. Broader by necessity, which is exactly why it is a
# different identity from the deploy account.
resource "google_service_account" "terraform" {
  account_id   = "jenie-terraform"
  display_name = "Jenie Terraform"
  project      = var.project_id

  depends_on = [google_project_service.enabled]
}

resource "google_project_iam_member" "deploy" {
  for_each = toset(var.deploy_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_project_iam_member" "terraform" {
  for_each = toset(var.terraform_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform.email}"
}

resource "google_storage_bucket_iam_member" "terraform_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform.email}"
}

# Only workflows running in this repository may impersonate these accounts.
locals {
  github_principal = join("", [
    "principalSet://iam.googleapis.com/",
    google_iam_workload_identity_pool.github.name,
    "/attribute.repository/",
    var.github_repository,
  ])
}

resource "google_service_account_iam_member" "deploy_federated" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_principal
}

resource "google_service_account_iam_member" "terraform_federated" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.github_principal
}

# ---------------------------------------------------------------------------
# Cost control
# ---------------------------------------------------------------------------

# A budget does not cap spend; it makes spend visible before the invoice
# does. Worth having from the first day on a project that can autoscale.
resource "google_billing_budget" "project" {
  count = var.billing_account == null ? 0 : 1

  billing_account = var.billing_account
  display_name    = "Jenie ${var.project_id}"

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.monthly_budget)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Forecast catches a runaway before the money is actually gone.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.enabled]
}
