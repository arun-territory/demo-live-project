output "docs_bucket" {
  value       = module.rag.docs_bucket
  description = "Upload documents here. Format: gs://<this-bucket-name>/your.pdf"
}

output "snapshots_bucket" {
  value       = module.rag.snapshots_bucket
  description = "Qdrant snapshots are written here every 6 hours."
}

output "rag_runtime_sa" {
  value = module.rag.rag_runtime_sa
}

output "rag_ingestion_sa" {
  value = module.rag.rag_ingestion_sa
}

output "qdrant_runtime_sa" {
  value = module.rag.qdrant_runtime_sa
}

output "qdrant_backup_sa" {
  value = module.rag.qdrant_backup_sa
}
