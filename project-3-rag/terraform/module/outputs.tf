output "docs_bucket" {
  value       = google_storage_bucket.docs.name
  description = "GCS bucket where users upload documents for ingestion"
}

output "snapshots_bucket" {
  value       = google_storage_bucket.snapshots.name
  description = "GCS bucket holding Qdrant snapshots"
}

output "rag_runtime_sa" {
  value       = google_service_account.rag_runtime.email
  description = "GCP SA for rag-runtime (query-api + embeddings)"
}

output "rag_ingestion_sa" {
  value       = google_service_account.rag_ingestion.email
  description = "GCP SA for the ingestion CronJob"
}

output "qdrant_runtime_sa" {
  value       = google_service_account.qdrant_runtime.email
  description = "GCP SA for Qdrant pods"
}

output "qdrant_backup_sa" {
  value       = google_service_account.qdrant_backup.email
  description = "GCP SA for the Qdrant snapshot CronJob"
}

output "docs_events_topic" {
  value       = var.enable_event_driven_ingestion ? google_pubsub_topic.docs_events[0].name : ""
  description = "Pub/Sub topic for GCS object events (empty if event-driven ingestion disabled)"
}
