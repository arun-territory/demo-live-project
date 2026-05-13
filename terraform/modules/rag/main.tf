# Buckets, IAM, and (optionally) a Pub/Sub notification for event-driven
# ingestion. The CronJob path works without Pub/Sub; turn on
# var.enable_event_driven_ingestion to also publish object-create events.
#
# Buckets:
#   ${project_id}-rag-docs         user-uploaded documents (ingestion input)
#   ${project_id}-qdrant-snapshots Qdrant snapshot backups
#
# Service accounts created here (matched to the K8s SA annotations):
#   rag-runtime          query-api + embeddings   secret reader
#   rag-ingestion        ingestion CronJob        bucket reader + secret reader
#   qdrant-runtime       Qdrant pods              secret reader
#   qdrant-backup        backup CronJob           snapshot bucket writer

locals {
  docs_bucket      = "${var.project_id}-rag-docs"
  snapshots_bucket = "${var.project_id}-qdrant-snapshots"
}

# ── Buckets ──────────────────────────────────────────────────────────────────

resource "google_storage_bucket" "docs" {
  name                        = local.docs_bucket
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age                = 30
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }

  labels = var.labels
}

resource "google_storage_bucket" "snapshots" {
  name                        = local.snapshots_bucket
  project                     = var.project_id
  location                    = var.region
  storage_class               = "NEARLINE"
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy_buckets

  versioning {
    enabled = false
  }

  lifecycle_rule {
    condition {
      age = var.snapshot_retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = var.labels
}

# ── Service accounts ─────────────────────────────────────────────────────────

resource "google_service_account" "rag_runtime" {
  account_id   = "rag-runtime"
  display_name = "RAG query-api + embeddings runtime"
  project      = var.project_id
}

resource "google_service_account" "rag_ingestion" {
  account_id   = "rag-ingestion"
  display_name = "RAG ingestion job"
  project      = var.project_id
}

resource "google_service_account" "qdrant_runtime" {
  account_id   = "qdrant-runtime"
  display_name = "Qdrant server runtime"
  project      = var.project_id
}

resource "google_service_account" "qdrant_backup" {
  account_id   = "qdrant-backup"
  display_name = "Qdrant snapshot backup job"
  project      = var.project_id
}

# ── IAM bindings (project-level scoped to the secrets/buckets we own) ────────

# Secret Manager access for runtime SAs
resource "google_project_iam_member" "rag_runtime_secret_reader" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.rag_runtime.email}"
}

resource "google_project_iam_member" "rag_ingestion_secret_reader" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.rag_ingestion.email}"
}

resource "google_project_iam_member" "qdrant_runtime_secret_reader" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.qdrant_runtime.email}"
}

# Bucket-level access
resource "google_storage_bucket_iam_member" "ingestion_read_docs" {
  bucket = google_storage_bucket.docs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.rag_ingestion.email}"
}

resource "google_storage_bucket_iam_member" "backup_write_snapshots" {
  bucket = google_storage_bucket.snapshots.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.qdrant_backup.email}"
}

# Workload Identity bindings — K8s SA -> GCP SA
resource "google_service_account_iam_member" "rag_runtime_wi" {
  service_account_id = google_service_account.rag_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[rag/rag-runtime]"
}

resource "google_service_account_iam_member" "rag_ingestion_wi" {
  service_account_id = google_service_account.rag_ingestion.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[rag/rag-ingestion]"
}

resource "google_service_account_iam_member" "qdrant_runtime_wi" {
  service_account_id = google_service_account.qdrant_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[qdrant/qdrant]"
}

resource "google_service_account_iam_member" "qdrant_backup_wi" {
  service_account_id = google_service_account.qdrant_backup.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[qdrant/qdrant-backup]"
}

# ── Optional: event-driven ingestion via Pub/Sub ─────────────────────────────

resource "google_pubsub_topic" "docs_events" {
  count   = var.enable_event_driven_ingestion ? 1 : 0
  name    = "rag-docs-events"
  project = var.project_id
  labels  = var.labels
}

# Allow GCS to publish to the topic
data "google_storage_project_service_account" "gcs" {
  count   = var.enable_event_driven_ingestion ? 1 : 0
  project = var.project_id
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  count   = var.enable_event_driven_ingestion ? 1 : 0
  project = var.project_id
  topic   = google_pubsub_topic.docs_events[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs[0].email_address}"
}

resource "google_storage_notification" "docs" {
  count          = var.enable_event_driven_ingestion ? 1 : 0
  bucket         = google_storage_bucket.docs.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.docs_events[0].id
  event_types    = ["OBJECT_FINALIZE", "OBJECT_DELETE"]
  depends_on     = [google_pubsub_topic_iam_member.gcs_publisher]
}
