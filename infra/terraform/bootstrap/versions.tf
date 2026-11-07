terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # No backend block on purpose.
  #
  # This configuration creates the bucket the environments keep their state
  # in, so it cannot keep its own state there on the first run. Its state
  # stays local and is git ignored. Losing it is recoverable: every resource
  # here is idempotent to recreate or can be imported.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}
