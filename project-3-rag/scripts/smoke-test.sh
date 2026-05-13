#!/usr/bin/env bash
# End-to-end RAG smoke test:
#   1. Upload a sample doc to GCS docs bucket
#   2. Trigger ingestion (manual Job — faster than waiting for the CronJob)
#   3. POST a question to the query API; assert the answer references the doc
#
# Requires: PROJECT_ID + RAG_API_KEY env vars + kubectl context.
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${RAG_API_KEY:?Set RAG_API_KEY (one of the keys in Secret Manager:rag-api-keys)}"

BUCKET="${PROJECT_ID}-rag-docs"
TMPFILE="$(mktemp).txt"
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" <<'EOF'
Project Falcon is an internal initiative at Acme Corp to consolidate
customer billing systems. It was approved on March 14, 2025 with a
budget of $4.2M and a target completion date of December 31, 2026.
The technical lead is Priya Subramanian.
EOF

echo "==> Uploading sample doc to gs://${BUCKET}/falcon.txt"
gsutil cp "$TMPFILE" "gs://${BUCKET}/falcon.txt"

echo "==> Triggering ingestion job"
kubectl -n rag create job --from=cronjob/ingestion "ingest-smoke-$(date +%s)"
sleep 2
JOB="$(kubectl -n rag get jobs -l job-name --sort-by=.metadata.creationTimestamp -o name | tail -1)"
echo "==> Waiting for $JOB to complete..."
kubectl -n rag wait --for=condition=complete --timeout=5m "$JOB"

echo "==> Port-forwarding query-api..."
kubectl -n rag port-forward svc/query-api 18080:80 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true; rm -f "$TMPFILE"' EXIT
sleep 3

echo "==> Querying..."
RESPONSE=$(curl -fsS -X POST http://localhost:18080/query \
  -H "X-API-Key: ${RAG_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query": "What is the budget for Project Falcon and who leads it?"}')

echo "==> Response:"
echo "$RESPONSE" | python3 -m json.tool

if echo "$RESPONSE" | grep -q "falcon.txt"; then
  echo "==> PASS: cited the source document"
else
  echo "==> FAIL: source not cited"
  exit 1
fi
