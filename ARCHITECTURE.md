# Architecture

## Overview

A private, OpenAI-compatible LLM inference platform on GKE. All traffic stays inside the customer's VPC; the only egress is the initial model pull from HuggingFace via Cloud NAT.

```
                                                  ┌────────────────────────┐
                                                  │  GCP Secret Manager    │
                                                  │   - hf-token           │
                                                  │   - api-keys           │
                                                  └────────────┬───────────┘
                                                               │ (Workload Identity)
                                                               │
┌──────────────────────────────────────────────────────────────┼──────────────────────┐
│ Private VPC  (10.20.0.0/16)                                  │                      │
│                                                              ▼                      │
│  ┌────────────────────────┐    ┌──────────────────────────────────────────┐         │
│  │ Subnet: nodes          │    │  GKE Control Plane (private endpoint)    │         │
│  │   10.20.10.0/24        │    │  Authorized network: ops bastion only    │         │
│  └────────────────────────┘    └──────────────────────────────────────────┘         │
│                                                                                     │
│  ┌────────────────────────┐    ┌────────────────────────┐                           │
│  │ Subnet: pods (sec.)    │    │ Subnet: services       │                           │
│  │   10.21.0.0/16         │    │   10.22.0.0/20         │                           │
│  └────────────────────────┘    └────────────────────────┘                           │
│                                                                                     │
│   ┌──── ns: gateway ────┐    ┌──── ns: vllm ────┐    ┌── ns: monitoring ──┐         │
│   │ Internal LB         │    │ vLLM Deployment  │    │ kube-prom-stack    │         │
│   │   │                 │    │   - Gemma 2 9B   │    │   - Prometheus     │         │
│   │   ▼                 │    │   - L4 GPU       │    │   - Grafana        │         │
│   │ apikey-gateway      │───▶│   - HPA (queue)  │◀───│   - Alertmanager   │         │
│   │  (FastAPI)          │    │ NetworkPolicy:    │    │ Prom Adapter       │         │
│   │  validates X-API-Key│    │   deny-all + LL  │    │   queue→HPA metric │         │
│   └─────────────────────┘    └──────────────────┘    └────────────────────┘         │
│                                                                                     │
│   ┌──── ns: platform ───┐                                                           │
│   │ cert-manager        │                                                           │
│   │ external-secrets-op │                                                           │
│   └─────────────────────┘                                                           │
│                                                                                     │
└────────────────────────────────────┬────────────────────────────────────────────────┘
                                     │
                              ┌──────▼──────┐
                              │  Cloud NAT  │  (egress-only — HF model download)
                              └─────────────┘
```

## Request flow

1. Client (in the same VPC, or peered VPC, or via Cloud VPN) hits the internal load balancer at `https://llm.internal.example.com/v1/chat/completions`.
2. Ingress terminates TLS using a cert from cert-manager (Let's Encrypt DNS-01).
3. Request lands on `apikey-gateway` pod. The gateway:
   - Validates `X-API-Key` against a key set loaded from Secret Manager via External Secrets Operator.
   - Rejects with 401 if invalid.
   - Forwards the request as-is to the vLLM service.
4. The vLLM pod runs Gemma 2 9B with PagedAttention. It:
   - Returns OpenAI-format chat completions.
   - Exposes Prometheus metrics on `:8000/metrics`, including `vllm:num_requests_waiting`.
5. Prometheus Adapter exposes `num_requests_waiting` as a custom metric to the K8s API.
6. The HPA on the vLLM deployment scales replicas based on **average waiting requests per pod**, not CPU.
7. When desired replicas exceed available GPU nodes, the cluster autoscaler provisions another L4 node from the GPU pool (min = 0, so it can also scale all the way down).

## Why each major choice

| Decision | Why |
|---|---|
| **GKE over GKE Autopilot** | Need explicit node-pool control for GPUs and spot instances. Autopilot's GPU support is improving but adds opaque pricing. |
| **vLLM over TGI / TorchServe** | Highest throughput per GPU thanks to PagedAttention + continuous batching. OpenAI-compatible server included. |
| **Gemma 2 9B over Llama 3.1 8B** | Open license (no click-through gating). Comparable quality. Fits an L4 (24GB VRAM) with `bfloat16` and reasonable `--max-model-len`. |
| **L4 over A100/H100** | 4× cheaper per hour. Sufficient for 9B-class models at moderate QPS. Scale horizontally for more load. |
| **HPA on queue depth, not CPU** | CPU/memory don't correlate with LLM load. Queue depth is the true backpressure signal. |
| **Internal LB only** | Customers' clients live inside their VPC (apps, jobs). Public LB is unnecessary and a security risk. |
| **Workload Identity + External Secrets** | Eliminates the entire class of leaked-service-account-key incidents. Industry standard for GKE. |
| **API-key gateway as a sidecar pod** | Portable across clouds. Cloud IAP is more powerful but ties you to GCP-only auth. Documented as a future option. |
| **cert-manager DNS-01** | Works for internal-only domains (no public HTTP-01 challenge possible since LB isn't reachable). |
| **kube-prometheus-stack** | One Helm release, ServiceMonitor CRD ecosystem, dashboards-as-code via ConfigMaps. |
| **Spot GPU + scheduled shutdown** | Single biggest cost lever. Spot saves 60–70%; nightly shutdown saves another 30–40% on dev. |

## Threat model summary

See [`security.md`](security.md) for the full list. The top mitigations:

| Threat | Mitigation |
|---|---|
| Stolen credentials → cluster access | Workload Identity (no keys); private control plane; authorized networks |
| Model exfiltration via the inference endpoint | Internal LB only; API-key auth; per-key rate limit (future) |
| Lateral movement from a compromised pod | NetworkPolicy default-deny in `vllm` namespace; restricted PSS |
| Supply chain — malicious base image | Artifact Registry vulnerability scanning; pinned digests in prod |
| Cost runaway | Billing alerts; spot nodes; scheduled scale-to-zero; HPA upper bound |
| Secret leakage in git | `.gitignore` for `*.tfvars`, `*service-account*.json`; pre-commit hook (optional) |

## Cost model (rough, us-central1)

- **Cluster (regional)**: $0.10/hr ≈ $72/month — always on
- **CPU pool (1 × e2-standard-4 spot)**: $0.025/hr ≈ $18/month
- **GPU pool (L4 spot, scales 0 → N)**: $0.21/hr per node when active
- **Internal LB**: ~$18/month
- **Cloud NAT**: ~$45/month + data egress
- **Storage / logging / monitoring**: ~$20/month

**Idle**: ~$170/month (cluster + CPU + LB + NAT + observability — no GPU).
**Active inference** (1 L4 running 8 hr/day): ~$220/month.
**Scheduled shutdown of dev cluster nights+weekends**: cuts the above roughly in half.

See [`cost.md`](cost.md) for the math behind $/1M tokens.
