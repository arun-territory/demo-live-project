#!/usr/bin/env bash
# Deploy only the RAG tier (Qdrant + embeddings + query-api + ingestion).
# Assumes the inference platform (vLLM + gateway) is already running.
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:=us-central1}"
: "${CLUSTER_NAME:=dev-genai-inference}"
: "${REGISTRY:=us-central1-docker.pkg.dev/${PROJECT_ID}/genai}"
: "${RAG_HOSTNAME:=rag.internal.example.com}"
: "${INFERENCE_HOSTNAME:=llm.internal.example.com}"
: "${CERT_EMAIL:=platform@example.com}"

echo "==> Deploying RAG tier to cluster=${CLUSTER_NAME} region=${REGION}"

render() {
  sed -e "s|PROJECT_ID|${PROJECT_ID}|g" \
      -e "s|REGION|${REGION}|g" \
      -e "s|CLUSTER_NAME|${CLUSTER_NAME}|g" \
      -e "s|REGISTRY|${REGISTRY}|g" \
      -e "s|rag.internal.example.com|${RAG_HOSTNAME}|g" \
      -e "s|llm.internal.example.com|${INFERENCE_HOSTNAME}|g" \
      -e "s|platform@example.com|${CERT_EMAIL}|g" \
      "$1"
}

apply_dir() {
  local dir="$1"
  echo "==> Applying $dir"
  for f in $(find "$dir" -name '*.yaml' | sort); do
    render "$f" | kubectl apply -f -
  done
}

apply_dir kubernetes/qdrant
echo "==> Waiting for Qdrant cluster..."
kubectl -n qdrant rollout status statefulset/qdrant --timeout=10m

apply_dir kubernetes/rag
kubectl -n rag rollout status deployment/embeddings --timeout=5m
kubectl -n rag rollout status deployment/query-api --timeout=5m

echo
echo "==> RAG tier ready."
echo "    Endpoint:    https://${RAG_HOSTNAME}/query"
echo "    Upload docs: gsutil cp file.pdf gs://${PROJECT_ID}-rag-docs/"
echo "    Ingestion CronJob runs every 5 min."
