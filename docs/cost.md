# Cost

## TL;DR — set these three things on day zero

1. **Billing alert** at $30 (warning) and $100 (critical):
   ```
   https://console.cloud.google.com/billing/<billing-account>/budgets
   ```
2. **Spot nodes** enabled on both pools (default in `terraform.tfvars.example`). Saves 60–70%.
3. **`make destroy` muscle memory** at the end of every dev session. Even cheaper than spot.

## Cost breakdown (us-central1, May 2026 list prices)

| Resource | Unit cost | Notes |
|---|---|---|
| **Regional GKE cluster fee** | $0.10 / hour | Flat — runs whether you have nodes or not. ~$72/mo |
| **e2-standard-4 (CPU) on-demand** | $0.134 / hour | Cluster system pods, gateway, monitoring |
| **e2-standard-4 (CPU) spot** | $0.04 / hour | 70% cheaper |
| **g2-standard-8 + L4 GPU on-demand** | ~$0.85 / hour | 1× L4, 32GB host RAM, 8 vCPU |
| **g2-standard-8 + L4 GPU spot** | ~$0.28 / hour | 65% cheaper, preemption risk |
| **Internal Load Balancer** | ~$0.025 / hour + data | ~$18/mo idle |
| **Cloud NAT** | $0.044 / hour + $0.045/GB | ~$32/mo idle + egress |
| **Cloud Logging** | $0.50 / GiB ingest after free tier | Usually small |
| **Persistent SSD** | $0.17 / GiB-month | Boot disks only — we use emptyDir for model cache |
| **L4 GPU egress (model pull)** | One-time | ~18GB for Gemma 2 9B; ~$0 within GCP, ~$1 to public internet |

## Three example monthly bills

**A. Dev, off nights+weekends, spot everywhere**
- Cluster fee: $72
- 1× CPU spot 24×7: $30
- 1× L4 spot 8h × 22 weekdays: $50
- LB + NAT + logs: ~$50
- **Total: ~$200/month**

**B. Dev, always on, on-demand**
- Cluster: $72
- 1× CPU on-demand 24×7: $97
- 1× L4 on-demand 24×7: $610
- LB + NAT + logs: ~$60
- **Total: ~$840/month**  (almost 4× the cost of A for marginal benefit)

**C. Prod, 1 warm + autoscaling, on-demand**
- Cluster: $72
- 2× CPU on-demand: $195
- 2× L4 on-demand 24×7 + autoscale to 4 during peaks: $1,300–1,800
- LB + NAT + logs: $100
- **Total: ~$1,700–$2,200/month**

## $/1M tokens model

For Gemma 2 9B on L4 with continuous batching:
- Sustained throughput at moderate concurrency: ~250 generated tokens/sec/GPU
- Hourly tokens per GPU: 250 × 3600 ≈ 900K tokens/hr
- On spot ($0.28/hr): $0.28 / 900K = **~$0.31 per 1M generated tokens**
- On on-demand ($0.85/hr): **~$0.94 per 1M generated tokens**

Compare to OpenAI gpt-4o-mini at the time of writing: ~$0.60 / 1M output tokens. Self-hosting Gemma 2 9B on spot L4 is **roughly 2× cheaper** at sustained load, plus the data privacy benefit.

Spot interruption rates vary 5–30% depending on region/time; build retry into clients.

## Cost guardrails in this repo

| Guard | Where | Effect |
|---|---|---|
| GPU pool min_nodes = 0 | `terraform/modules/node-pools/main.tf` | No GPU billing when idle |
| Spot on both pools (default) | `terraform.tfvars.example` | 60–70% off |
| HPA upper bound (4 replicas) | `kubernetes/vllm/hpa.yaml` | Caps runaway scale-up |
| Scheduled shutdown CronJob | `kubernetes/cost-controls/scheduled-shutdown.yaml` | Forces GPU pool to 0 nights/weekends |
| `make destroy` first scales GPU pool to 0 | `Makefile` | Stops GPU billing before slower terraform destroy |
| VPC flow logs sampled at 0.5 | `terraform/modules/network/main.tf` | Halves logging spend |
| Cloud NAT logs filtered to errors | `terraform/modules/network/main.tf` | Avoids verbose NAT log bill |
| Prometheus retention 15d (not default 90d) | `terraform/modules/platform/main.tf` | Smaller PV |

## Budget alert setup (one-time)

```bash
gcloud billing budgets create \
  --billing-account=YOUR-BILLING-ACCOUNT \
  --display-name="genai-inference dev" \
  --budget-amount=100USD \
  --threshold-rule=percent=30 \
  --threshold-rule=percent=70 \
  --threshold-rule=percent=100 \
  --filter-projects=projects/$PROJECT_ID
```

Email + Pub/Sub notifications fire at 30%, 70%, 100%. Wire the Pub/Sub topic into a Cloud Function that runs `make destroy` automatically if you want a hard ceiling.
