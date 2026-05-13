#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-dev}"
CLUSTER_NAME="${ENVIRONMENT}-ml-inference-cluster"

echo "==> Setting up ML Inference Platform for environment: ${ENVIRONMENT}"

# Validate tools
for tool in kubectl helm terraform aws; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' not found in PATH"
    exit 1
  fi
done

echo "==> Updating kubeconfig..."
aws eks update-kubeconfig --region us-east-1 --name "${CLUSTER_NAME}"

echo "==> Creating namespaces..."
kubectl apply -f kubernetes/base/namespace.yaml

echo "==> Installing NGINX Ingress Controller..."
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --wait

echo "==> Installing Prometheus stack..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait

echo "==> Deploying ML Inference Platform..."
helm upgrade --install ml-inference infrastructure/helm/ml-inference \
  --namespace "ml-inference-${ENVIRONMENT}" \
  --create-namespace \
  --wait

echo "==> Setup complete!"
kubectl get pods -n "ml-inference-${ENVIRONMENT}"
