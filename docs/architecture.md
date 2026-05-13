# Architecture (deep dive)

> The top-level diagram + design decisions live in [`/ARCHITECTURE.md`](../ARCHITECTURE.md). This doc is the deeper "why each piece exists" guide.

## Layer 1 — Network

A single, private VPC (`10.20.0.0/16`) with:
- One primary subnet for nodes (`10.20.10.0/24`)
- Two secondary ranges (alias IPs) for pods (`10.21.0.0/16`) and services (`10.22.0.0/20`)
- A `/28` reserved for the GKE control plane (`172.16.0.0/28`)
- Cloud NAT for egress (HF model download)
- Firewall: default-deny ingress + allow internal RFC1918

**Why private VPC?** Compliance teams demand it. Even if you trust GCP, the LL platform demos better and reads "production" only when there's not a public IP in sight.

**Why Cloud NAT?** vLLM needs to pull the model from HuggingFace at boot. Without NAT, the private nodes can't reach the public internet. NAT is egress-only — no inbound paths.

## Layer 2 — Compute

A regional GKE cluster with two node pools:

| Pool | Purpose | Machine | Taints | Spot |
|---|---|---|---|---|
| `cpu-pool` | System pods, gateway, monitoring, cert-manager, ESO | `e2-standard-4` | none | yes (dev) |
| `gpu-pool` | vLLM **only** | `g2-standard-8` + 1× L4 | `nvidia.com/gpu=present:NoSchedule` | yes (dev) |

**Why separate pools?** Cost. GPU nodes are 10× the price of CPU nodes — you don't want kube-proxy and Prometheus running on them. The taint ensures only pods that explicitly tolerate it land there.

**Why regional cluster?** Higher availability for the control plane (3 zones); the additional cost is small relative to the GPU bill.

**Why scale-to-zero on GPU pool?** This is the single biggest cost lever after spot. A dev cluster with `min_nodes=0` costs $0/hour for GPUs when not serving requests.

## Layer 3 — Platform addons

Installed via Helm from Terraform (`modules/platform/main.tf`):

- **kube-prometheus-stack** — Prometheus, Alertmanager, Grafana, all CRDs in one chart
- **prometheus-adapter** — bridges Prometheus metrics to the K8s custom-metrics API, so HPAs can scale on `vllm:num_requests_waiting`
- **cert-manager** — Let's Encrypt cert issuance via DNS-01 (DNS-01 is required because the LB is internal — there's no public HTTP-01 challenge path)
- **external-secrets** — pulls Secret Manager values into K8s Secrets, authenticating via Workload Identity (no service-account keys)

## Layer 4 — Workload

### vLLM (`kubernetes/vllm/`)
- Deployment with `nodeSelector: pool=gpu` + GPU toleration
- One container — the upstream `vllm/vllm-openai` image, no fork
- Args tuned for L4: `bfloat16`, `--gpu-memory-utilization 0.90`, `--max-model-len 8192`
- `emptyDir` for `/cache/hf` (model weights) — 50Gi, sized for Gemma 2 9B
- `emptyDir(medium: Memory)` for `/dev/shm` — vLLM needs ~4GB shared memory even at TP=1
- Startup probe with 10-minute window (model download takes time on first boot)
- HPA on `vllm_num_requests_waiting` (queue depth) — not CPU
- Network policy: ingress only from gateway + monitoring; egress for HF, GCP APIs, DNS
- PDB: `minAvailable: 1` so cluster upgrades don't take the whole service down

### API-key gateway (`kubernetes/gateway/`, `docker/apikey-gateway/`)
- 80-line FastAPI proxy that:
  - Reads keys from a file mounted from a K8s Secret (sourced via ESO from Secret Manager)
  - Validates `X-API-Key` (or `Authorization: Bearer`) on every request
  - Forwards everything else to vLLM unchanged → OpenAI SDK compatibility for free
- Runs on the CPU pool, 2 replicas, anti-affinity across nodes
- Exposes Prometheus metrics on a separate port (so they're not on the public path)
- Why not Kong/Apigee/Istio? Overkill for "validate one header". 80 lines is auditable in a single sitting.

### Ingress + TLS (`kubernetes/gateway/`)
- GKE internal LB (`kubernetes.io/ingress.class: gce-internal`)
- Cert provisioned by cert-manager via DNS-01 challenge to Cloud DNS
- FrontendConfig forces HTTP→HTTPS redirect

## Layer 5 — Observability

### Metrics
- vLLM exposes Prometheus metrics natively on `:8000/metrics`
- ServiceMonitor scrapes both vLLM and the gateway every 15s
- Prometheus retention: 15 days (cost trade-off — sufficient for week-over-week comparison)

### Dashboards (`kubernetes/observability/grafana-dashboard-cm.yaml`)
Pre-built dashboard with the panels every interviewer asks about:
- TTFT (time to first token) P50/P95/P99
- E2E latency P50/P95/P99
- Tokens/sec per pod
- Queue depth (`num_requests_waiting`)
- Running requests
- GPU memory used/free (requires DCGM exporter)
- GPU utilization %
- RPS by status

### Alerts (`kubernetes/observability/prometheusrule.yaml`)
- VLLMPodDown (1m)
- VLLMHighP99Latency (>5s for 5m)
- VLLMHighErrorRate (>1% for 2m)
- GPUMemoryHigh (>90% for 5m)
- VLLMQueueBacklog (>20 for 3m)

## Layer 6 — Cost controls

| Mechanism | Where | Saves |
|---|---|---|
| GPU pool min=0 | `terraform/modules/node-pools/main.tf` | All GPU cost when idle |
| Spot on both pools | `terraform.tfvars.example` | 60–70% off node cost |
| HPA `maxReplicas: 4` | `kubernetes/vllm/hpa.yaml` | Bounds peak spend |
| Cluster autoscaler `max_nodes: 4` | `terraform/modules/node-pools/main.tf` | Bounds GPU node count |
| Scheduled shutdown CronJob | `kubernetes/cost-controls/scheduled-shutdown.yaml` | ~60% on dev clusters |
| Prometheus retention 15d | `terraform/modules/platform/main.tf` | Smaller PV |
| VPC flow logs sampled 0.5 | `terraform/modules/network/main.tf` | Halves logging spend |
| `make destroy` GPU-first ordering | `Makefile` | Stops GPU billing fast |

## How a request flows (end-to-end)

1. Client (SDK call inside the VPC) → `https://llm.internal.example.com/v1/chat/completions`
2. GCE internal LB terminates TLS via cert from cert-manager
3. Forwarded to `apikey-gateway` pod (CPU pool)
4. Gateway reads `X-API-Key` (or `Bearer`), looks up the in-memory key set (re-read from a file every check, file is materialised by ESO)
5. If valid → forwards request via httpx to `http://vllm.vllm.svc.cluster.local:8000`
6. NetworkPolicy in `vllm` ns confirms the source pod is in `gateway` ns with `app=apikey-gateway` — otherwise drops the packet
7. vLLM tokenises, scheduler adds to batch, GPU generates, response streams back
8. Prometheus has been recording `vllm:num_requests_waiting` the whole time → HPA may already be requesting a scale-up
9. Gateway proxies the streamed response back to the client unmodified
10. Metrics on both sides recorded for Grafana

Total added latency from the gateway (network + auth check): single-digit milliseconds.
