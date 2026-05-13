# GCS-backed remote state. Bucket is created by scripts/bootstrap.sh before the
# first `terraform init`. Use a unique bucket name per project (the bootstrap
# script suggests `${PROJECT_ID}-tfstate`).
#
# To switch projects, override at init time:
#   terraform init -backend-config="bucket=my-project-tfstate"
terraform {
  backend "gcs" {
    bucket = "REPLACE-ME-tfstate"
    prefix = "shared-infra"
  }
}
