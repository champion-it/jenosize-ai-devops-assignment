#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key = "jenie/prod/terraform.tfstate"
  }
}
