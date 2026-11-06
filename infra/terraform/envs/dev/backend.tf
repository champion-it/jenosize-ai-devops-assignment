# State lives in a versioned GCS bucket, one prefix per environment, so dev
# can never overwrite prod state. Object versioning on the bucket is the
# recovery path if state is corrupted.
#
#   terraform init -backend-config=backend.hcl
terraform {
  backend "gcs" {
    prefix = "jenie/dev"
  }
}
