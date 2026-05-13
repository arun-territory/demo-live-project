# Project 3 — RAG infrastructure.
# This stack provisions:
#   - 2 GCS buckets (docs upload + Qdrant snapshots)
#   - 4 GCP service accounts (rag-runtime, rag-ingestion, qdrant-runtime,
#     qdrant-backup) with Workload Identity bindings to K8s SAs
#   - IAM bindings (Secret Manager reader, bucket read/write where appropriate)
#   - (optional) Pub/Sub topic for event-driven ingestion
#
# This stack does NOT manage the cluster or VPC. Those live in
# ../../shared-infra/terraform/ and must already be applied.

locals {
  common_labels = {
    project     = "genai-rag"
    environment = var.environment
    managed_by  = "terraform"
  }
}

module "rag" {
  source = "./module"

  project_id                    = var.project_id
  region                        = var.region
  labels                        = local.common_labels
  snapshot_retention_days       = var.qdrant_snapshot_retention_days
  force_destroy_buckets         = var.force_destroy_buckets
  enable_event_driven_ingestion = var.enable_event_driven_ingestion
}
