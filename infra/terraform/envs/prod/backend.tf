# See envs/dev/backend.tf. Prod state is in the same bucket under its own
# prefix, with a separate IAM binding so only the deploy service account and
# the platform team can read it.
#
#   terraform init -backend-config=backend.hcl
terraform {
  backend "gcs" {
    prefix = "jenie/prod"
  }
}
