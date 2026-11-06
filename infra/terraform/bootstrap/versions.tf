terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }
  }

  # Deliberately no backend block.
  #
  # This configuration creates the bucket the environments keep their state
  # in, so it cannot keep its own state there on the first run. Its state
  # stays local and is git ignored. Losing it is recoverable: every resource
  # here is either idempotent to recreate or can be imported.
}

provider "google" {
  project = var.project_id
  region  = var.region
}
