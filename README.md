# AI-ML Inference k8s Platform

A production-ready platform for deploying and serving machine learning models on Kubernetes with auto-scaling, monitoring, and multi-environment support.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Load Balancer / Ingress                   │
└────────────────────────────┬────────────────────────────────────┘
                             │
              ┌──────────────▼──────────────┐
              │        API Gateway           │
              │    (FastAPI + rate limit)     │
              └──────┬───────────────┬───────┘
                     │               │
         ┌───────────▼───┐   ┌───────▼──────────┐
         │  Inference     │   │  Model Registry   │
         │  Service Pods  │   │  (S3 / GCS)       │
         │  (GPU/CPU)     │   └──────────────────┘
         └───────┬────────┘
                 │
    ┌────────────▼────────────┐
    │   Monitoring Stack       │
    │  Prometheus + Grafana    │
    └─────────────────────────┘
```

## Features

- **Multi-model serving**: Deploy multiple ML models with isolated inference pods
- **Auto-scaling**: HPA and VPA based on request rate and GPU utilization
- **Multi-environment**: Dev / Staging / Production via Kustomize overlays
- **Observability**: Prometheus metrics, Grafana dashboards, structured logging
- **Helm chart**: One-command deployment with configurable values
- **Terraform**: EKS cluster provisioning with GPU node groups
- **CI/CD**: GitHub Actions pipelines for build, test, and deploy

## Quick Start

### Prerequisites

- Kubernetes 1.27+
- Helm 3.x
- kubectl
- Terraform 1.5+ (for cloud provisioning)
- Docker

### Deploy with Helm

```bash
# Add dependencies
helm dependency update infrastructure/helm/ml-inference

# Deploy to dev
helm upgrade --install ml-inference infrastructure/helm/ml-inference \
  --namespace ml-inference \
  --create-namespace \
  -f infrastructure/helm/ml-inference/values.yaml

# Deploy to production
helm upgrade --install ml-inference infrastructure/helm/ml-inference \
  --namespace ml-inference-prod \
  --create-namespace \
  -f infrastructure/helm/ml-inference/values-prod.yaml
```

### Deploy with Kustomize

```bash
# Dev environment
kubectl apply -k kubernetes/overlays/dev

# Staging
kubectl apply -k kubernetes/overlays/staging

# Production
kubectl apply -k kubernetes/overlays/prod
```

### Provision EKS with Terraform

```bash
cd infrastructure/terraform
terraform init
terraform plan -var-file="environments/prod.tfvars"
terraform apply -var-file="environments/prod.tfvars"
```

## Project Structure

```
.
├── .github/workflows/          # CI/CD pipelines
├── infrastructure/
│   ├── terraform/              # EKS cluster + networking
│   └── helm/ml-inference/      # Helm chart
├── kubernetes/
│   ├── base/                   # Base k8s manifests
│   ├── overlays/               # Kustomize overlays per environment
│   └── monitoring/             # Prometheus + Grafana configs
├── src/
│   ├── api/                    # FastAPI inference gateway
│   └── model_server/           # Model loading + serving logic
├── docker/                     # Dockerfiles
├── scripts/                    # Utility scripts
└── tests/                      # Unit + integration tests
```

## API Reference

### POST /v1/infer

Run inference on a deployed model.

```json
{
  "model_name": "resnet50",
  "model_version": "1.0.0",
  "inputs": [
    {
      "name": "image",
      "data": "<base64-encoded-data>",
      "shape": [1, 3, 224, 224],
      "datatype": "FP32"
    }
  ]
}
```

### GET /v1/models

List all deployed models and their status.

### GET /healthz

Liveness probe endpoint.

### GET /readyz

Readiness probe endpoint.

## Monitoring

Access Grafana at `http://<ingress-host>/grafana` (default credentials in `kubernetes/monitoring/`).

Key dashboards:
- **Inference Latency**: p50/p95/p99 latency per model
- **Throughput**: Requests/sec and token/sec
- **GPU Utilization**: Per-node GPU memory and compute usage
- **Error Rates**: 4xx/5xx breakdown by model and endpoint

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Run tests: `./scripts/test.sh`
4. Submit a pull request

## License

Apache 2.0
