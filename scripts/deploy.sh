#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-dev}"
IMAGE_TAG="${2:-latest}"
NAMESPACE="ml-inference-${ENVIRONMENT}"

echo "==> Deploying ml-inference to ${ENVIRONMENT} with tag ${IMAGE_TAG}"

helm upgrade --install ml-inference infrastructure/helm/ml-inference \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set image.tag="${IMAGE_TAG}" \
  --atomic \
  --timeout 10m \
  --wait

echo "==> Deployment status:"
kubectl rollout status deployment/ml-inference -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=ml-inference
