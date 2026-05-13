# GCS-backed remote state. Uses the SAME bucket as shared-infra, but with
# a different prefix so the two stacks have separate state files.
#
# The bucket is created by scripts/bootstrap.sh in the repo root.
terraform {
  backend "gcs" {
    bucket = "REPLACE-ME-tfstate"
    prefix = "project-3-rag"
  }
}
