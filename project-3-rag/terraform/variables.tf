variable "project_id" {
  type        = string
  description = "GCP project ID (same project as shared-infra)."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region for buckets (match shared-infra)."
}

variable "environment" {
  type        = string
  default     = "dev"
}

variable "qdrant_snapshot_retention_days" {
  type        = number
  default     = 30
  description = "How long to keep Qdrant snapshots in GCS."
}

variable "force_destroy_buckets" {
  type        = bool
  default     = false
  description = "Allow `terraform destroy` to delete non-empty RAG buckets. Dev-only — flip to true if you want clean teardown."
}

variable "enable_event_driven_ingestion" {
  type        = bool
  default     = false
  description = "Provision a Pub/Sub topic + GCS notification for object-create events. The 5-minute CronJob works without this."
}
