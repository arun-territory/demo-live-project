# Shared Infrastructure

**This builds the empty cluster that both projects run on.** You do this **once**, before deploying either Project 1 or Project 3.

## What this folder does

Think of this as **buying a piece of land and building an empty warehouse on it**. The warehouse has:
- Walls (private network — VPC)
- A floor plan (Kubernetes cluster — GKE)
- Storage rooms (node pools — where things actually run)
- Plumbing and electricity (Prometheus, cert-manager, External Secrets — the platform addons)

After this is done, the warehouse is empty. **No AI runs here yet.** Project 1 and Project 3 are the "tenants" that move in later.

## What gets created in your GCP account

| Resource | What it is | Cost |
|---|---|---|
| 1 VPC | Private network, no public IPs | ~$0 |
| 1 GKE cluster (regional) | Kubernetes control plane in 3 zones | ~$72/month |
| 1 CPU node pool | 1–3 small VMs for system pods | ~$20/month (spot) |
| 1 GPU node pool | 0–4 VMs with NVIDIA L4. **0 when idle** | ~$0 when idle |
| Cloud NAT | Lets pods download things from the internet | ~$45/month |
| Prometheus + Grafana + cert-manager + ESO | Observability + secrets + TLS | ~$0 (runs on CPU pool) |

**Idle cost: ~$170/month.** GPU cost only when Project 1 is actively serving requests.

## How to use it

### One-time setup (~5 minutes)

```bash
# From the repo root, NOT from this folder:
export PROJECT_ID=your-gcp-project-id
export REGION=us-central1
bash scripts/bootstrap.sh
```

This enables GCP APIs and creates a GCS bucket to store Terraform's state.

### Configure (~2 minutes)

```bash
cd shared-infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set your project_id
```

### Deploy (~15 minutes)

```bash
cd shared-infra
make apply
```

When this finishes, run:

```bash
make kubeconfig
kubectl get nodes
```

You should see 1–2 nodes. The empty warehouse is ready.

### Tear it all down

```bash
make destroy
```

Warning: this destroys the cluster. Make sure you've torn down Project 1 and Project 3 workloads first (see their READMEs).

## What's inside

```
shared-infra/
├── README.md           ← you are here
├── Makefile            ← apply / destroy / kubeconfig
└── terraform/
    ├── main.tf         ← wires the four modules together
    ├── variables.tf    ← input variables (region, cluster_name, etc)
    ├── outputs.tf      ← exports cluster info for the projects
    ├── backend.tf      ← where Terraform stores its state (GCS)
    ├── providers.tf    ← GCP provider versions
    └── modules/
        ├── network/    ← VPC, Cloud NAT, firewall
        ├── gke/        ← GKE cluster with Workload Identity
        ├── node-pools/ ← CPU pool + GPU pool (scale to zero)
        └── platform/   ← Helm releases: prometheus, cert-manager, ESO
```

## Next steps

After this folder is deployed and you can run `kubectl get nodes`:

1. Go to **`project-1-inference/`** and follow its README. That deploys the LLM.
2. (Later) Go to **`project-3-rag/`** and follow its README. That deploys the RAG layer on top.

Each project has its own README, Makefile, and scripts. They don't know about each other.
