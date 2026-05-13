# Security

## Threat model

We assume a determined attacker who may:
- Compromise a workload pod in the cluster
- Phish a developer credential
- Compromise an upstream container image (supply chain)
- Try to abuse the inference endpoint (model exfiltration, prompt injection, DoS)
- Run up costs to deny service or burn budget

We do **not** defend against:
- A compromised GCP project owner
- Physical access to Google's data center

## Control matrix

| Layer | Threat | Control | Where it lives |
|---|---|---|---|
| **Identity** | Leaked SA key → full project access | Workload Identity (no keys); GitHub Actions via Workload Identity Federation | `terraform/modules/gke/main.tf`; `.github/workflows/terraform.yml` |
| **Identity** | Over-privileged service account | Minimal node SA (logWriter, metricWriter, AR reader only); per-workload GCP SAs | `terraform/modules/gke/main.tf`; `kubernetes/*/serviceaccount.yaml` |
| **Network — perimeter** | Public exposure of the LLM | Internal LB only; no public IPs on cluster nodes; egress via Cloud NAT | `terraform/modules/network/main.tf`; `kubernetes/gateway/ingress.yaml` |
| **Network — control plane** | Public master endpoint | Private GKE control plane + authorized networks | `terraform/modules/gke/main.tf` |
| **Network — east/west** | Lateral movement from a compromised pod | Default-deny NetworkPolicy in `vllm` and `gateway`; explicit allows only | `kubernetes/vllm/networkpolicy.yaml`; `kubernetes/gateway/networkpolicy.yaml` |
| **Workload** | Container escape | Restricted Pod Security Standards on every namespace; non-root UID; `readOnlyRootFilesystem`; drop ALL caps; `seccompProfile: RuntimeDefault` | `kubernetes/*/namespace.yaml`; `kubernetes/*/deployment.yaml` |
| **Supply chain** | Compromised base image | Artifact Registry vulnerability scanning; pinned image digests in prod (TODO); hadolint in CI | GCP project setting; `.github/workflows/lint.yml` |
| **Secrets** | Secret in git | `.gitignore` covers `*.tfvars`, `*service-account*.json`; External Secrets Operator pulls from Secret Manager at runtime | `.gitignore`; `kubernetes/*/externalsecret.yaml` |
| **Auth at endpoint** | Anonymous use of the LLM | API-key gateway sidecar validates `X-API-Key` against Secret Manager-sourced keys | `docker/apikey-gateway/main.py` |
| **Auth at endpoint** | Stolen/leaked API key | Multiple keys per environment; rotate by editing the Secret Manager entry (ESO refreshes every 5 min) | `kubernetes/gateway/externalsecret.yaml` |
| **TLS** | MITM on internal traffic | cert-manager + Let's Encrypt DNS-01; cert refreshed 30d before expiry | `kubernetes/gateway/certificate.yaml` |
| **Cost / DoS** | Runaway GPU spend | GCP billing alerts; spot nodes; HPA upper bound; cluster autoscaler max; scheduled scale-to-zero CronJob | `docs/cost.md`; `kubernetes/cost-controls/scheduled-shutdown.yaml` |
| **Observability** | Slow incident detection | Prometheus alerts: GPU mem >90%, P99 >5s, error rate >1%, queue backlog | `kubernetes/observability/prometheusrule.yaml` |
| **Audit** | Insufficient forensics | GKE audit logs enabled (API, ADMIN, controller, scheduler); VPC flow logs on; Cloud NAT logs on errors | `terraform/modules/gke/main.tf`; `terraform/modules/network/main.tf` |

## What this project does NOT solve (yet)

| Gap | Mitigation when you need it |
|---|---|
| Per-API-key rate limiting | Add a token-bucket counter in the gateway, or front with Cloud Armor / a real API gateway (Apigee, Kong) |
| Prompt injection / output filtering | Add a content-moderation layer (Llama Guard, Azure Content Safety) before/after vLLM |
| Audit log of who called what | Add request/response logging in the gateway (mind PII!) — write to a separate audit log sink |
| Multi-tenant isolation | One vLLM Deployment per tenant, or model-server routing tier |
| Encryption with customer-managed keys (CMEK) | Enable CMEK on PVs and Artifact Registry — minimal Terraform changes |
| Confidential VMs | Switch node pools to `n2d-standard` with AMD SEV — small perf cost, big compliance win |

## Rotating API keys

```bash
# Add a new key, keep the old one for one rotation window
NEW=$(openssl rand -hex 32)
gcloud secrets versions access latest --secret=vllm-api-keys \
  | (cat; echo; echo "$NEW") \
  | gcloud secrets versions add vllm-api-keys --data-file=-

# After clients migrate, remove the old key by re-writing the secret.
```

ESO refreshes the in-cluster Secret within 5 minutes (`refreshInterval`).

## Rotating the HF token

```bash
gcloud secrets versions add hf-token --data-file=<(echo -n "$NEW_HF_TOKEN")
# vLLM pods will pick up the new token on next restart. Force with:
kubectl -n vllm rollout restart deployment/vllm
```
