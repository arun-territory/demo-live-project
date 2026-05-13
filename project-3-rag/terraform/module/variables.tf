variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region for buckets"
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Common labels"
}

variable "snapshot_retention_days" {
  type        = number
  default     = 30
  description = "Days to keep Qdrant snapshots in GCS before lifecycle deletion"
}

variable "force_destroy_buckets" {
  type        = bool
  default     = false
  description = "Allow terraform destroy to delete non-empty buckets. ENABLE FOR DEV ONLY."
}

variable "enable_event_driven_ingestion" {
  type        = bool
  default     = false
  description = "Provision Pub/Sub topic + GCS notification for object-create events. The CronJob-based ingestion in kubernetes/rag/ingestion-cronjob.yaml works without this."
}
