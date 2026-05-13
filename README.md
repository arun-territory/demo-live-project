# Private GenAI Inference Platform on GKE

> Self-hosted, OpenAI-compatible LLM API on Google Kubernetes Engine. Private VPC, GPU autoscaling to zero, full observability, enterprise security controls. One `make apply` from zero to a running endpoint.

## The problem this solves

Every BFSI, healthcare, legal, and large-product company in 2026 wants to use LLMs — but **cannot send sensitive data to OpenAI / Anthropic** because of DPDP, GDPR, HIPAA, or trade-secret concerns. They have Kubernetes expertise but not LLM-serving expertise. This platform closes that gap: a reproducible, private LLM inference stack their data never leaves.

## Architecture

```
                         ┌──────────────────────────────────────┐
                         │  Private VPC (10.20.0.0/16)          │
   In-VPC clients ─────► │                                       │
                         │   Internal LB ──► API Gateway (auth)  │
                         │                     │                 │
                         │                     ▼                 │
                         │              vLLM (Gemma 2 9B)        │
                         │              L4 GPU pool (min=0)      │
                         │                     │                 │
                         │   Prometheus ◄──────┘                 │
                         │   Grafana                             │
                         │                                       │
                         │   ▲  Workload Identity                │
                         │   │  External Secrets ◄── Secret Mgr  │
                         └───┼───────────────────────────────────┘
                             │
                       Cloud NAT  (egress only — HF model pull)
```

See [`docs/architecture.md`](docs/architecture.md) for the full diagram and design decisions.

## What's inside

| Concern | What you get |
|---|---|
| **Inference engine** | vLLM serving Gemma 2 9B, OpenAI-compatible API (`/v1/chat/completions`) |
| **Compute** | Private GKE 1.29 with separate CPU + L4 GPU node pools, GPU pool scales to **0** when idle |
| **Networking** | Private VPC, custom subnets, Cloud NAT for egress, **internal** load balancer only |
| **Identity** | Workload Identity (no static service-account keys), External Secrets Operator + GCP Secret Manager |
| **Auth at the edge** | API-key gateway sidecar (FastAPI) — validates `X-API-Key` before forwarding to vLLM |
| **TLS** | cert-manager + Let's Encrypt (DNS-01 via Cloud DNS) |
| **Network policy** | Default-deny in `vllm` namespace; only the gateway can reach vLLM |
| **Pod security** | Restricted Pod Security Standards on all namespaces |
| **Autoscaling** | HPA on `vllm:num_requests_waiting` (queue depth) via Prometheus Adapter — not CPU |
| **Observability** | kube-prometheus-stack + a custom Grafana dashboard for TTFT, tokens/sec, queue depth, GPU util, GPU memory, P50/P95/P99 |
| **Alerts** | GPU memory > 90%, P99 > 5s, error rate > 1%, inference pod down |
| **Cost controls** | Spot GPU nodes, scheduled scale-to-zero CronJob, billing alerts (instructions in `docs/cost.md`) |
| **IaC** | Modular Terraform with GCS-backed state, GitHub Actions plan-on-PR / apply-on-main |
| **Teardown** | `make destroy` — one command, billing-safe by default |

## Quickstart

### Prereqs
- `gcloud`, `terraform >= 1.5`, `kubectl`, `helm >= 3.14`, `make`
- A GCP project with billing enabled
- L4 GPU quota in your region (request via [`scripts/bootstrap.sh`](scripts/bootstrap.sh) — it prints the link)
- A HuggingFace token (free; for downloading Gemma 2)

### Five commands from zero to inference

```bash
# 1. Bootstrap: enable APIs, create the tfstate bucket, prompt for quota
./scripts/bootstrap.sh

# 2. Edit terraform/terraform.tfvars (copy from .example)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars

# 3. Stand up the platform (VPC, GKE, node pools, prom-stack, cert-manager, ESO)
make apply

# 4. Deploy the workload (vLLM, gateway, ingress, network policies, dashboards)
make deploy

# 5. Smoke-test
make smoke-test
```

### Calling the endpoint (OpenAI-compatible)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://llm.internal.example.com/v1",
    api_key="<your-api-key-from-secret-manager>",
)

resp = client.chat.completions.create(
    model="google/gemma-2-9b-it",
    messages=[{"role": "user", "content": "Summarise the DPDP Act in 3 bullets."}],
)
print(resp.choices[0].message.content)
```

### Tearing it down (billing safety)

```bash
make destroy
```

Tears down node pools first (stops GPU billing fastest), then cluster, then network.

## Repo layout

```
terraform/         # Modular IaC: network, gke, node-pools, platform (Helm releases)
kubernetes/        # vLLM workload, gateway, observability, cost-controls
docker/            # API-key gateway image
scripts/           # bootstrap, deploy, teardown, smoke-test, load-test
docs/              # architecture, security, cost, runbook
tests/integration/ # OpenAI-SDK e2e + network policy enforcement tests
.github/workflows/ # terraform plan/apply, lint
```

## What makes this production-grade (interview answer)

1. **Private by default** — no public IPs on the cluster control plane or workloads. Egress only via Cloud NAT.
2. **No static credentials** — Workload Identity + External Secrets Operator. Service-account keys never touch the repo.
3. **Defense in depth** — network policies, restricted Pod Security Standards, image vulnerability scanning, API-key auth at the edge.
4. **Real autoscaling** — HPA on queue depth, cluster autoscaler scales the GPU pool to zero. You pay for GPUs only when serving requests.
5. **Operable** — pre-built Grafana dashboard, alert rules, runbook for the top five oncall scenarios.
6. **Cost-aware** — spot GPUs, scheduled shutdown, $/1M-tokens dashboard, billing alerts documented.
7. **Reproducible** — every byte of infrastructure is in Terraform, peer-reviewed in PRs, state in a locked GCS bucket.

## Roadmap

- **Phase 2** (this repo, next): Private RAG platform — Qdrant + automated GCS-triggered ingestion + retrieval API on the same GKE cluster.
- **Phase 3**: Multi-tenant model routing, per-tenant quotas, OpenTelemetry traces across embed → retrieve → generate.

## License

Apache 2.0
