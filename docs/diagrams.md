# Architecture Diagrams — End-to-End Flows

All diagrams use ASCII so they render in any editor / on GitHub without plugins.

Contents:
1. [High-level cloud architecture](#1-high-level-cloud-architecture)
2. [Network topology](#2-network-topology)
3. [End-to-end request flow](#3-end-to-end-request-flow)
4. [Secret management flow](#4-secret-management-flow)
5. [Autoscaling flow](#5-autoscaling-flow)
6. [Deployment & CI/CD flow](#6-deployment--cicd-flow)
7. [Observability flow](#7-observability-flow)
8. [Cost-control flow](#8-cost-control-flow)
9. [Security boundaries](#9-security-boundaries)

---

## 1. High-level cloud architecture

```
                                  ┌──────────────────────┐
                                  │   GCP Project        │
                                  │                      │
   ┌──────────────────┐           │  ┌───────────────┐   │
   │   Developer      │──gcloud──▶│  │  IAM / WIF    │   │
   │   (laptop)       │           │  └───────────────┘   │
   └──────────────────┘           │  ┌───────────────┐   │
                                  │  │ Secret Manager│   │
   ┌──────────────────┐           │  │  - hf-token   │   │
   │  GitHub Actions  │──WIF─────▶│  │  - api-keys   │   │
   │  (CI/CD)         │           │  └───────────────┘   │
   └──────────────────┘           │  ┌───────────────┐   │
                                  │  │ Artifact Reg. │   │
                                  │  │  gateway img  │   │
                                  │  └───────────────┘   │
                                  │  ┌───────────────┐   │
                                  │  │ Cloud DNS     │   │
                                  │  │  internal zone│   │
                                  │  └───────────────┘   │
                                  │  ┌───────────────┐   │
                                  │  │ Cloud Logging │   │
                                  │  │ Cloud Monitor │   │
                                  │  └───────────────┘   │
                                  └──────────┬───────────┘
                                             │
                  ┌──────────────────────────┴────────────────────────────┐
                  │                  Private VPC (10.20.0.0/16)           │
                  │                                                       │
                  │   ┌────────────────────────────────────────────┐      │
                  │   │           GKE Cluster (regional)           │      │
                  │   │                                            │      │
                  │   │  ┌─────────────┐         ┌─────────────┐   │      │
                  │   │  │  CPU Pool   │         │  GPU Pool   │   │      │
                  │   │  │ e2-std-4    │         │ g2-std-8    │   │      │
                  │   │  │ spot, 1-3   │         │ +L4, 0-4    │   │      │
                  │   │  │             │         │ spot, taint │   │      │
                  │   │  │ - gateway   │         │ - vllm      │   │      │
                  │   │  │ - prom      │         │             │   │      │
                  │   │  │ - grafana   │         │             │   │      │
                  │   │  │ - certmgr   │         │             │   │      │
                  │   │  │ - ESO       │         │             │   │      │
                  │   │  └─────────────┘         └─────────────┘   │      │
                  │   └────────────────────────────────────────────┘      │
                  │                                                       │
                  │   ┌──────────────┐    ┌──────────────┐                │
                  │   │ Internal LB  │    │  Cloud NAT   │ ──▶ HuggingFace│
                  │   │ (gce-int)    │    │ (egress only)│                │
                  │   └──────────────┘    └──────────────┘                │
                  └────────────┬─────────────────────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────────┐
                  │  Client (in-VPC or VPN)  │
                  │  OpenAI SDK              │
                  └──────────────────────────┘
```

---

## 2. Network topology

```
   Internet  ─X── (no inbound; private cluster)
              │
              │ (egress only via Cloud NAT for HF model download)
              ▼
   ┌────────────────────────────────────────────────────────────┐
   │  VPC: vllm-platform-vpc          CIDR: 10.20.0.0/16        │
   │                                                            │
   │  ┌──────────────────────────────────────────────────────┐  │
   │  │ Subnet (primary):  10.20.10.0/24  — nodes            │  │
   │  │   ├─ Secondary: 10.21.0.0/16     — pods              │  │
   │  │   └─ Secondary: 10.22.0.0/20     — services          │  │
   │  └──────────────────────────────────────────────────────┘  │
   │                                                            │
   │  Control plane:  172.16.0.0/28  (private endpoint)         │
   │                                                            │
   │  Firewall rules:                                           │
   │   ├─ default-deny ingress (no public)                      │
   │   ├─ allow-internal RFC1918                                │
   │   └─ allow GCP health-check ranges (35.191/130.211)        │
   │                                                            │
   │  Cloud Router ─── Cloud NAT ─── egress to internet         │
   └────────────────────────────────────────────────────────────┘

   K8s NetworkPolicies (layer-2 on top of the above):

   default ns ────X────▶  vllm ns           (lateral movement blocked)
   gateway ns ─────────▶  vllm ns:8000      (allowed by label match)
   monitoring ns ──────▶  vllm ns:8000      (Prometheus scrape)
   anyone ─────────────▶  gateway ns:8080   (from LB health-check ranges)
```

---

## 3. End-to-end request flow

A single `POST /v1/chat/completions` from a client to first token:

```
┌─────────┐                     ┌──────────────┐                 ┌──────────────┐
│ Client  │                     │ Internal LB  │                 │  Gateway     │
│ SDK     │                     │ (gce-int)    │                 │  (FastAPI)   │
└────┬────┘                     └──────┬───────┘                 └──────┬───────┘
     │                                 │                                │
     │  POST /v1/chat/completions      │                                │
     │  Host: llm.internal.example.com │                                │
     │  X-API-Key: <key>               │                                │
     │  TLS                            │                                │
     │────────────────────────────────▶│                                │
     │                                 │                                │
     │                                 │ Terminate TLS                  │
     │                                 │ (cert from cert-manager)       │
     │                                 │                                │
     │                                 │  Forward HTTP/1.1              │
     │                                 │───────────────────────────────▶│
     │                                 │                                │
     │                                 │                          ┌─────┴─────┐
     │                                 │                          │ Check key │
     │                                 │                          │ vs file   │
     │                                 │                          │ from ESO  │
     │                                 │                          └─────┬─────┘
     │                                 │                                │
     │                                 │                                │ valid? ─── no ──▶ 401
     │                                 │                                │ yes
     │                                 │                                ▼
     │                                 │                       ┌──────────────┐
     │                                 │                       │ NetworkPolicy│
     │                                 │                       │ checks: src= │
     │                                 │                       │ gateway ns + │
     │                                 │                       │ label match  │
     │                                 │                       └──────┬───────┘
     │                                 │                              │ allowed
     │                                 │                              ▼
     │                                 │                       ┌──────────────┐
     │                                 │                       │ vLLM pod     │
     │                                 │                       │ (L4 GPU)     │
     │                                 │                       │              │
     │                                 │                       │ tokenize ──▶ │
     │                                 │                       │ scheduler ──▶│
     │                                 │                       │  add to batch│
     │                                 │                       │ GPU forward ▶│
     │                                 │                       │ stream out  │
     │                                 │                       └──────┬───────┘
     │                                 │                              │
     │                                 │      stream chunks back      │
     │                                 │◀─────────────────────────────│
     │                                 │                              │
     │       streamed tokens           │                              │
     │◀────────────────────────────────│                              │
     │                                 │                              │
     │                                 │                              ▼
     │                                 │                       ┌──────────────┐
     │                                 │                       │ Prometheus   │
     │                                 │                       │ scrapes mtrx │
     │                                 │                       │  - latency   │
     │                                 │                       │  - tokens/s  │
     │                                 │                       │  - queue dep │
     │                                 │                       └──────────────┘
```

Latency budget (approximate, in-region, warm):

| Hop | Time |
|---|---|
| Client → Internal LB (in-VPC) | 1–2 ms |
| LB TLS + routing | <1 ms |
| Gateway auth check | 0.5–1 ms |
| Gateway → vLLM (in-cluster) | <1 ms |
| vLLM tokenize + queue | 5–20 ms |
| **Time to first token** | **~30–60 ms** for short prompts |
| Per output token | ~4–8 ms (≈ 250 tok/s on L4) |

---

## 4. Secret management flow

How HuggingFace token and API keys flow from GCP Secret Manager into pods without static credentials:

```
┌─────────────────────────────────────────────────────────────────┐
│ Admin (one-time setup)                                          │
│                                                                 │
│   $ gcloud secrets create hf-token --data-file=token.txt        │
│   $ gcloud secrets create vllm-api-keys --data-file=keys.txt    │
│                                                                 │
│   $ gcloud iam service-accounts create vllm-runtime ...         │
│   $ gcloud projects add-iam-policy-binding \                    │
│       --role=roles/secretmanager.secretAccessor                 │
│   $ gcloud iam service-accounts add-iam-policy-binding \        │
│       --role=roles/iam.workloadIdentityUser                     │
│       --member="...svc.id.goog[vllm/vllm-runtime]"              │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
   ┌────────────────────┐    ┌──────────────────────┐
   │ GCP Secret Manager │    │  GCP Service Account │
   │  hf-token          │    │  vllm-runtime@...    │
   │  vllm-api-keys     │    │  Roles: secret reader│
   └─────────┬──────────┘    └──────────┬───────────┘
             │                          │
             │     (impersonation via Workload Identity)
             │                          │
             ▼                          ▼
   ┌─────────────────────────────────────────────┐
   │  External Secrets Operator (in cluster)     │
   │                                             │
   │  SecretStore (gcpsm) — uses K8s SA          │
   │  ExternalSecret — fetches every 1h          │
   └─────────┬───────────────────────────────────┘
             │  creates/updates
             ▼
   ┌─────────────────────────────────────────────┐
   │  K8s Secret: vllm/hf-token                  │
   │  K8s Secret: gateway/vllm-api-keys          │
   └─────────┬───────────────────────────────────┘
             │  mounted as
             ▼
   ┌─────────────────────────────────────────────┐
   │  vLLM pod      → env HUGGING_FACE_HUB_TOKEN │
   │  Gateway pod   → file /etc/api-keys/keys    │
   └─────────────────────────────────────────────┘

Rotation:
   1. Update Secret Manager version
   2. ESO refreshes within 1h (or force: kubectl annotate externalsecret ...)
   3. Gateway re-reads keys file on every request → no restart needed
   4. vLLM needs pod restart only if hf-token rotates (rare)
```

---

## 5. Autoscaling flow

How a load spike triggers pod scale + node provisioning:

```
   t=0   Load test starts: 200 concurrent users hit /v1/chat/completions
                                  │
                                  ▼
   t=1s  vllm_num_requests_waiting > 5 (queue building)
                                  │
                                  ▼
        ┌───────────────────────────────────────┐
        │ vLLM pod exposes /metrics             │
        │   vllm:num_requests_waiting{}=15      │
        └────────────────┬──────────────────────┘
                         │ scrape (15s)
                         ▼
        ┌───────────────────────────────────────┐
        │ Prometheus stores time series         │
        └────────────────┬──────────────────────┘
                         │ query
                         ▼
        ┌───────────────────────────────────────┐
        │ Prometheus Adapter                    │
        │   rule: vllm:num_requests_waiting     │
        │     → custom-metrics API as           │
        │       pods/vllm_num_requests_waiting  │
        └────────────────┬──────────────────────┘
                         │ k8s API
                         ▼
        ┌───────────────────────────────────────┐
        │ HPA controller (every 15s)            │
        │  current=15  target=5  replicas=1     │
        │  desired = ceil(15/5) = 3             │
        └────────────────┬──────────────────────┘
                         │ patches Deployment
                         ▼
        ┌───────────────────────────────────────┐
        │ Deployment: replicas=3                │
        └────────────────┬──────────────────────┘
                         │
                         ▼
   t=20s ┌───────────────────────────────────────┐
        │ Scheduler tries to place 2 new pods   │
        │ → Pending (no GPU node available)     │
        └────────────────┬──────────────────────┘
                         │ unschedulable
                         ▼
        ┌───────────────────────────────────────┐
        │ Cluster Autoscaler                    │
        │  sees pending pods, scans node pools  │
        │  picks gpu-pool (matches GPU request) │
        │  resizes from 1 → 3 nodes             │
        └────────────────┬──────────────────────┘
                         │
                         ▼
   t=2m  ┌───────────────────────────────────────┐
        │ New GKE nodes Ready, GPU drivers       │
        │ installed (LATEST), node-labels added  │
        └────────────────┬──────────────────────┘
                         │
                         ▼
   t=2m─12m ┌────────────────────────────────────┐
           │ vLLM pods schedule, pull image,    │
           │ download model (or hit PVC cache), │
           │ pass startupProbe                  │
           └────────────────┬───────────────────┘
                            ▼
   t=12m  Queue drains, latency restored to baseline

   Scale-down (configured to be slow on purpose):
   ───────────────────────────────────────────
   When queue falls below threshold:
   - HPA waits 600s stabilization (scaleDown.stabilizationWindowSeconds)
   - Then reduces replicas one at a time
   - Cluster Autoscaler removes empty GPU nodes after 10min idle
   - At min_nodes=0, the whole GPU pool eventually drains to zero
```

---

## 6. Deployment & CI/CD flow

How code gets from a developer's laptop to running pods:

```
   Developer                  GitHub                    GCP
   ─────────                  ──────                    ───
       │
       │ git push branch
       ├──────────────────────▶
       │                       │
       │                       │ PR opened
       │                       │
       │                       ▼
       │              ┌─────────────────────┐
       │              │ lint.yml workflow   │
       │              │  - yamllint         │
       │              │  - hadolint         │
       │              │  - kubeconform      │
       │              │  - tflint           │
       │              │  - pytest gateway   │
       │              └─────────────────────┘
       │              ┌─────────────────────┐
       │              │ terraform.yml plan  │
       │              │  - tf fmt           │
       │              │  - tf init (GCS)    │──auth via WIF──▶ GCP
       │              │  - tf plan          │
       │              │  - PR comment       │
       │              └─────────────────────┘
       │                       │
       │ ◀────  review ────────│
       │                       │
       │ merge to main         │
       ├──────────────────────▶│
       │                       │
       │                       ▼
       │              ┌─────────────────────┐
       │              │ terraform.yml apply │
       │              │ (gated: environment │──auth via WIF──▶ GCP: terraform apply
       │              │  = production)      │                   GKE/VPC/Helm
       │              └─────────────────────┘
       │
       │ (separately) make deploy
       └─────────────────────────────────────────▶ kubectl apply
                                                   GKE workloads
   Image build (manual or via separate workflow):

   docker build → docker push → REGISTRY/apikey-gateway:VERSION
                                       │
                                       ▼
                       referenced in kubernetes/gateway/deployment.yaml
```

---

## 7. Observability flow

Where metrics, logs, traces, and alerts originate and flow:

```
   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
   │  vLLM pod   │    │ Gateway pod │    │  Node       │
   │             │    │             │    │             │
   │ :8000/metrics│   │ :9100/metrics│   │ DCGM exp.   │
   │  - latency  │    │  - reqs     │    │  - GPU util │
   │  - tokens/s │    │  - auth fail│    │  - VRAM     │
   │  - queue    │    │             │    │             │
   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘
          │                  │                  │
          │  ServiceMonitor  │ ServiceMonitor   │ ServiceMonitor
          │     (15s)        │    (15s)         │    (15s)
          ▼                  ▼                  ▼
   ┌───────────────────────────────────────────────────┐
   │              Prometheus (15-day retention)        │
   │                                                   │
   │  ┌────────────────────────────────────────────┐   │
   │  │ Recording rules                            │   │
   │  │   vllm:e2e_latency_p99                     │   │
   │  │   vllm:tokens_per_sec                      │   │
   │  │   vllm:error_rate                          │   │
   │  └────────────────────────────────────────────┘   │
   │  ┌────────────────────────────────────────────┐   │
   │  │ Alerting rules                             │   │
   │  │   VLLMPodDown               (1m)           │   │
   │  │   VLLMHighP99Latency        (>5s, 5m)      │   │
   │  │   VLLMHighErrorRate         (>1%, 2m)      │   │
   │  │   GPUMemoryHigh             (>90%, 5m)     │   │
   │  │   VLLMQueueBacklog          (>20, 3m)      │   │
   │  └────────────────────────────────────────────┘   │
   └───────┬─────────────────────┬─────────────────────┘
           │                     │
           ▼                     ▼
   ┌───────────────┐    ┌───────────────────────┐
   │  Grafana      │    │  Alertmanager         │
   │               │    │                       │
   │  vLLM dash:   │    │  → PagerDuty/Slack    │
   │   TTFT, e2e   │    │     (configure in     │
   │   tokens/s    │    │      Helm values)     │
   │   queue depth │    │                       │
   │   GPU mem/util│    └───────────────────────┘
   │   RPS by code │
   └───────────────┘

   Logs (separate path):
   - All pod stdout/stderr → Cloud Logging (automatic via GKE)
   - kubectl logs for ad-hoc debugging
```

---

## 8. Cost-control flow

The four mechanisms that prevent runaway spend:

```
   ┌──────────────────────────────────────────────────────────┐
   │  1. SPOT INSTANCES        — saves 60-70% per node-hour   │
   │     Both CPU and GPU pools use spot.                     │
   │     Risk: preemption. Mitigation: HPA + PDB.             │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │  2. SCALE-TO-ZERO         — GPU pool min_nodes = 0       │
   │     Idle GPU cost = $0 (the biggest cost driver)         │
   │     Cold start trade-off: ~2min node provision           │
   │                          + ~10min first model download   │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │  3. SCHEDULED SHUTDOWN    — CronJob in cost-controls/    │
   │                                                          │
   │     22:00 IST  ─────────────┐                            │
   │     (cron "30 16 * * 1-5")  │                            │
   │                             ▼                            │
   │                     gcloud container clusters resize     │
   │                       --node-pool=gpu-pool               │
   │                       --num-nodes=0                      │
   │                                                          │
   │     09:00 IST  ─────────────┐                            │
   │     (cron "30 3 * * 1-5")   │                            │
   │                             ▼                            │
   │                     gcloud container node-pools update   │
   │                       --min-nodes=1 --max-nodes=4        │
   └──────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────┐
   │  4. HARD CEILINGS         — bounds peak spend            │
   │     HPA max_replicas         = 4                         │
   │     Cluster Autoscaler max   = 4 GPU nodes               │
   │     Worst-case GPU bill: 4 × $0.28/hr × 730 hrs = $820/mo│
   │     (and that assumes 100% utilization — never happens)  │
   └──────────────────────────────────────────────────────────┘

   Plus: GCP Billing Alert (configure once)
   ────────────────────────────────────────
   gcloud billing budgets create \
     --display-name="vllm-platform" \
     --budget-amount=300 \
     --threshold-rule=percent=0.5,basis=current-spend \
     --threshold-rule=percent=0.9,basis=current-spend
```

---

## 9. Security boundaries

Layered defense — what stops what:

```
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 1 — NETWORK                                        ║
   ║  Private cluster + private endpoint                      ║
   ║  Internal LB only (no public IP)                         ║
   ║  Cloud NAT for egress only (no inbound path)             ║
   ║  Firewall: default-deny ingress                          ║
   ║       STOPS: external attackers, model exfil via public  ║
   ╚══════════════════════════════════════════════════════════╝
                            │
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 2 — AUTHENTICATION                                 ║
   ║  API-key gateway: X-API-Key or Authorization: Bearer     ║
   ║  Keys stored in Secret Manager, rotated via ESO          ║
   ║       STOPS: in-VPC unauthorized clients                 ║
   ╚══════════════════════════════════════════════════════════╝
                            │
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 3 — KUBERNETES NETWORK POLICIES                    ║
   ║  Default-deny in vllm namespace                          ║
   ║  Only gateway ns (label match) → vllm:8000               ║
   ║  Only monitoring ns → vllm:8000 (scrape)                 ║
   ║       STOPS: lateral movement from compromised pods      ║
   ╚══════════════════════════════════════════════════════════╝
                            │
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 4 — POD SECURITY                                   ║
   ║  Restricted PSS (namespaces labeled enforce=restricted)  ║
   ║  runAsNonRoot, runAsUser=1000                            ║
   ║  drop ALL capabilities                                   ║
   ║  seccompProfile: RuntimeDefault                          ║
   ║  readOnlyRootFilesystem (gateway)                        ║
   ║       STOPS: container escape via root/cap exploits      ║
   ╚══════════════════════════════════════════════════════════╝
                            │
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 5 — IDENTITY                                       ║
   ║  Workload Identity (no static SA keys in pods)           ║
   ║  WIF for GitHub Actions (no SA keys in repo)             ║
   ║  Node SA: minimal roles (logWriter, metricWriter, AR ro) ║
   ║       STOPS: leaked-key-causes-cluster-compromise        ║
   ╚══════════════════════════════════════════════════════════╝
                            │
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 6 — SUPPLY CHAIN                                   ║
   ║  Multi-stage Docker, non-root UID 1000                   ║
   ║  hadolint + kubeconform in CI                            ║
   ║  Artifact Registry vuln scanning (auto)                  ║
   ║  Pinned chart versions in Helm releases                  ║
   ║       STOPS: malicious base images, drift on apply       ║
   ╚══════════════════════════════════════════════════════════╝
                            │
   ╔══════════════════════════════════════════════════════════╗
   ║ Layer 7 — AUDIT                                          ║
   ║  GKE audit logs: API, ADMIN, controller, scheduler       ║
   ║  Cloud Logging retention (configurable)                  ║
   ║  GCS state bucket versioning + object retention          ║
   ║       SUPPORTS: forensics, compliance reporting          ║
   ╚══════════════════════════════════════════════════════════╝
```

---

## Quick reference — file → role mapping

| File | What it produces in the diagram |
|---|---|
| `terraform/modules/network/main.tf` | Layer 1 (VPC, NAT, firewall) |
| `terraform/modules/gke/main.tf` | Private cluster, Workload Identity pool |
| `terraform/modules/node-pools/main.tf` | CPU pool, GPU pool with scale-to-zero |
| `terraform/modules/platform/main.tf` | Prometheus stack, ESO, cert-manager |
| `kubernetes/vllm/deployment.yaml` | vLLM pod (Gemma 2 9B on L4) |
| `kubernetes/vllm/hpa.yaml` | HPA on queue depth |
| `kubernetes/vllm/networkpolicy.yaml` | Layer 3 ingress controls |
| `kubernetes/gateway/deployment.yaml` | FastAPI gateway pod |
| `kubernetes/gateway/ingress.yaml` | Internal LB + TLS |
| `kubernetes/observability/*` | ServiceMonitors, alerts, dashboard |
| `kubernetes/cost-controls/*` | Scheduled scale-to-zero |
| `docker/apikey-gateway/main.py` | Layer 2 authentication |
| `.github/workflows/*` | CI/CD pipeline (Section 6) |
