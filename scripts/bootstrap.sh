#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time bootstrap for a new GCP project.
#   1. Enable required APIs
#   2. Create a GCS bucket for Terraform state (with versioning)
#   3. Print the URL to request L4 GPU quota
#   4. Patch terraform/backend.tf to point at the new bucket
# Re-running is idempotent.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Set PROJECT_ID or run: gcloud config set project <id>" >&2
  exit 1
fi

echo "==> Project: ${PROJECT_ID}"
echo "==> Region:  ${REGION}"

echo "==> Enabling APIs..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudresourcemanager.googleapis.com \
  dns.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

BUCKET="${PROJECT_ID}-tfstate"
echo "==> Creating tfstate bucket: gs://${BUCKET}"
if ! gsutil ls -b "gs://${BUCKET}" &>/dev/null; then
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  gcloud storage buckets update "gs://${BUCKET}" --versioning
else
  echo "    bucket exists, skipping"
fi

echo "==> Patching terraform/backend.tf..."
sed -i.bak "s|REPLACE-ME-tfstate|${BUCKET}|g" terraform/backend.tf
rm -f terraform/backend.tf.bak

echo
echo "==> L4 GPU quota request:"
echo "    https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
echo "    Filter: 'NVIDIA L4 GPUs' for region '${REGION}'. Request at least 1."
echo
echo "==> Done. Next: cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
echo "             then 'make apply'"
