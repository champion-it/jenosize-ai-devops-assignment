# The cluster is shared, so its state is neither dev's nor prod's.
#
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key = "jenie/cluster/terraform.tfstate"
  }
}
