#!/usr/bin/env bash
# Billing-safe teardown:
#   1. Scale GPU pool to 0 (stops GPU billing immediately)
#   2. Delete workloads
#   3. terraform destroy
set -euo pipefail

: "${REGION:=us-central1}"
: "${CLUSTER_NAME:=dev-genai-inference}"

echo "==> Step 1/3: Scaling GPU pool to 0..."
gcloud container clusters resize "${CLUSTER_NAME}" \
  --node-pool=gpu-pool --region="${REGION}" --num-nodes=0 --quiet || true

echo "==> Step 2/3: Deleting workloads..."
kubectl delete --ignore-not-found -f kubernetes/cost-controls/
kubectl delete --ignore-not-found -f kubernetes/observability/
kubectl delete --ignore-not-found -f kubernetes/gateway/
kubectl delete --ignore-not-found -f kubernetes/vllm/

echo "==> Step 3/3: terraform destroy..."
( cd terraform && terraform destroy -auto-approve )

echo "==> Done. Confirm in console:"
echo "    https://console.cloud.google.com/billing"
