#!/usr/bin/env bash
# Apply Kubernetes manifests in dependency order, substituting placeholder
# values (PROJECT_ID, REGION, CLUSTER_NAME, REGISTRY, INFERENCE_HOSTNAME) at
# apply time. We avoid kustomize-overlay sprawl by doing simple envsubst —
# the templates are small enough.
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:=us-central1}"
: "${CLUSTER_NAME:=dev-genai-inference}"
: "${REGISTRY:=us-central1-docker.pkg.dev/${PROJECT_ID}/genai}"
: "${INFERENCE_HOSTNAME:=llm.internal.example.com}"
: "${CERT_EMAIL:=platform@example.com}"

echo "==> Deploying to cluster=${CLUSTER_NAME} region=${REGION}"

# envsubst-style replacement (no envsubst dep required)
render() {
  sed -e "s|PROJECT_ID|${PROJECT_ID}|g" \
      -e "s|REGION|${REGION}|g" \
      -e "s|CLUSTER_NAME|${CLUSTER_NAME}|g" \
      -e "s|REGISTRY|${REGISTRY}|g" \
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

apply_dir kubernetes/vllm
apply_dir kubernetes/gateway
apply_dir kubernetes/observability
apply_dir kubernetes/cost-controls

echo "==> Waiting for vLLM to become ready (model download can take 5–10 min)..."
kubectl -n vllm rollout status deployment/vllm --timeout=15m

echo "==> Gateway:"
kubectl -n gateway rollout status deployment/apikey-gateway --timeout=5m

echo
echo "==> Deployment complete. Endpoint:"
echo "    https://${INFERENCE_HOSTNAME}/v1/chat/completions"
echo "    (header: X-API-Key: <one of the keys in Secret Manager:vllm-api-keys>)"
