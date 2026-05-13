# Implementation Guide — Private GKE vLLM Inference Platform

Step-by-step instructions to go from zero to a running Gemma 2 9B endpoint on GKE.
Estimated time: 60–90 minutes (plus ~15 minutes for first model download).

---

## Prerequisites

### Tools (install all before starting)

```bash
# Google Cloud SDK
curl https://sdk.cloud.google.com | bash
gcloud components install gke-gcloud-auth-plugin

# Terraform >= 1.7
brew install terraform        # macOS
# OR: https://developer.hashicorp.com/terraform/install

# kubectl
gcloud components install kubectl

# Helm >= 3.14
brew install helm

# Docker (for building the gateway image)
# https://docs.docker.com/engine/install/

# Optional — load testing
pip install locust
```

### Accounts and access

| What | Where |
|---|---|
| GCP project with billing enabled | console.cloud.google.com |
| Owner or Editor + Security Admin IAM role | console.cloud.google.com/iam-admin |
| L4 GPU quota in your region | console.cloud.google.com/iam-admin/quotas → filter "NVIDIA_L4_GPUS" |
| HuggingFace account + token | huggingface.co/settings/tokens |
| Access to `google/gemma-2-9b-it` model | huggingface.co/google/gemma-2-9b-it → Request access |
| Artifact Registry repository (created in Step 3) | — |

### GPU quota check

Before you start, verify you have at least **1 NVIDIA_L4_GPU** quota in your target region:

```bash
gcloud compute regions describe us-central1 \
  --format="table(quotas[].metric, quotas[].limit, quotas[].usage)" \
  | grep NVIDIA_L4
```

If limit is 0, request an increase at the URL printed by `bootstrap.sh` (Step 3).

---

## Step 1 — Clone the repository

```bash
git clone https://github.com/arun-territory/demo-live-project.git
cd demo-live-project
git checkout claude/create-ai-ml-k8s-project-LvJBG
```

---

## Step 2 — Authenticate to GCP

```bash
gcloud auth login
gcloud auth application-default login

# Set your project
gcloud config set project YOUR_PROJECT_ID
```

Replace `YOUR_PROJECT_ID` with your GCP project ID throughout this guide.

---

## Step 3 — Bootstrap GCP (one-time)

This script enables APIs, creates the Terraform state bucket, and patches `terraform/backend.tf`.

```bash
export PROJECT_ID=YOUR_PROJECT_ID
export REGION=us-central1       # change if you prefer a different region

bash scripts/bootstrap.sh
```

What it does:
- Enables 9 GCP APIs (container, compute, iam, secretmanager, artifactregistry, etc.)
- Creates GCS bucket `${PROJECT_ID}-tfstate` with versioning
- Patches `terraform/backend.tf` with the real bucket name
- Prints the L4 GPU quota request URL

Wait for all APIs to be enabled (~2 minutes) before continuing.

---

## Step 4 — Create Artifact Registry repository

The gateway Docker image is stored here.

```bash
gcloud artifacts repositories create vllm-platform \
  --repository-format=docker \
  --location=${REGION} \
  --description="vLLM platform images"
```

---

## Step 5 — Configure Terraform variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` — replace every placeholder:

```hcl
project_id   = "YOUR_PROJECT_ID"
region       = "us-central1"
environment  = "dev"
cluster_name = "vllm-platform"

# Keep defaults or adjust:
# cpu_pool.min_nodes = 1
# gpu_pool.min_nodes = 0   ← scale-to-zero (saves cost when idle)
# gpu_pool.max_nodes = 4
```

---

## Step 6 — Provision infrastructure with Terraform

```bash
make plan    # review what will be created (~35 resources)
make apply   # creates VPC, GKE cluster, node pools, Helm addons (~15 minutes)
```

What gets created:
- Private VPC with Cloud NAT
- Regional GKE cluster (3 zones, private nodes)
- CPU node pool (`e2-standard-4`, spot)
- GPU node pool (`g2-standard-8` + L4, spot, min=0)
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
- Prometheus Adapter (custom-metrics for HPA)
- cert-manager
- External Secrets Operator

After `make apply` completes:

```bash
make kubeconfig    # configures kubectl context
kubectl get nodes  # should show 1–2 cpu-pool nodes
```

---

## Step 7 — Store secrets in GCP Secret Manager

### 7a. HuggingFace token

```bash
echo -n "hf_YOUR_TOKEN_HERE" | gcloud secrets create hf-token \
  --data-file=- \
  --project=${PROJECT_ID}
```

Get your token at: huggingface.co/settings/tokens (read access is sufficient).

### 7b. API keys for the gateway

```bash
# Create a file with one key per line
cat > /tmp/api-keys.txt <<EOF
your-strong-api-key-1
your-strong-api-key-2
EOF

gcloud secrets create vllm-api-keys \
  --data-file=/tmp/api-keys.txt \
  --project=${PROJECT_ID}

rm /tmp/api-keys.txt   # don't leave keys on disk
```

---

## Step 8 — Bind Workload Identity for vLLM and gateway

These bindings let the Kubernetes pods authenticate to GCP without static keys.

### 8a. vLLM runtime service account

```bash
# Create the GCP service account
gcloud iam service-accounts create vllm-runtime \
  --display-name="vLLM Runtime" \
  --project=${PROJECT_ID}

# Grant Secret Manager access (needs the HF token)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:vllm-runtime@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Allow the K8s ServiceAccount to impersonate the GCP SA (Workload Identity binding)
gcloud iam service-accounts add-iam-policy-binding \
  vllm-runtime@${PROJECT_ID}.iam.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[vllm/vllm-runtime]" \
  --role="roles/iam.workloadIdentityUser"
```

### 8b. Gateway runtime service account

```bash
gcloud iam service-accounts create gateway-runtime \
  --display-name="Gateway Runtime" \
  --project=${PROJECT_ID}

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:gateway-runtime@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud iam service-accounts add-iam-policy-binding \
  gateway-runtime@${PROJECT_ID}.iam.gserviceaccount.com \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[gateway/gateway-runtime]" \
  --role="roles/iam.workloadIdentityUser"
```

---

## Step 9 — Build and push the API-key gateway image

```bash
export REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/vllm-platform"

# Authenticate Docker to Artifact Registry
gcloud auth configure-docker ${REGION}-docker.pkg.dev

# Build and push
docker build -t ${REGISTRY}/apikey-gateway:0.1.0 docker/apikey-gateway/
docker push ${REGISTRY}/apikey-gateway:0.1.0
```

---

## Step 10 — Deploy workloads to Kubernetes

```bash
export PROJECT_ID=YOUR_PROJECT_ID
export REGION=us-central1
export CLUSTER_NAME=vllm-platform
export REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/vllm-platform"

make deploy
```

The `deploy` script renders placeholders in all manifests and applies them in order:
1. `kubernetes/vllm/` — namespace, RBAC, ESO secrets, deployment, service, HPA, PDB, NetworkPolicy
2. `kubernetes/gateway/` — namespace, RBAC, ESO secrets, deployment, service, ingress, cert, NetworkPolicy
3. `kubernetes/observability/` — ServiceMonitors, PrometheusRules, Grafana dashboard
4. `kubernetes/cost-controls/` — scheduled GPU pool scale-to-zero CronJobs

### Verify deployments

```bash
# Watch vLLM pod come up (model download takes ~10 minutes on first boot)
kubectl -n vllm get pods -w

# Gateway should be ready faster
kubectl -n gateway get pods -w

# Check HPA is registered
kubectl -n vllm get hpa
```

Note: vLLM triggers GPU node provisioning. The autoscaler takes 1–3 minutes to add a node, then the pod takes ~10 minutes for first-time model download. Subsequent starts are faster if you add a PVC cache (see docs/runbook.md §6).

---

## Step 11 — Verify the cluster is healthy

```bash
# All pods in all namespaces
kubectl get pods -A

# vLLM logs (watch for "Application startup complete")
kubectl -n vllm logs deployment/vllm -f

# Check NetworkPolicies applied
kubectl -n vllm get networkpolicies
kubectl -n gateway get networkpolicies
```

---

## Step 12 — Run smoke tests

```bash
make smoke-test
```

This script:
1. Checks `/healthz` returns `{"status": "ok"}`
2. Verifies a missing API key returns 401
3. Sends a chat completion request and asserts a valid response

If the ingress hostname isn't reachable yet, the script falls back to `kubectl port-forward` automatically.

### Manual test (optional)

```bash
# Port-forward the gateway directly
kubectl -n gateway port-forward svc/apikey-gateway 8080:80 &

# Test
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/v1/models \
  -H "X-API-Key: your-strong-api-key-1" | jq .

curl -s http://localhost:8080/v1/chat/completions \
  -H "X-API-Key: your-strong-api-key-1" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-2-9b-it",
    "messages": [{"role": "user", "content": "What is 2+2?"}],
    "max_tokens": 64
  }' | jq .choices[0].message.content
```

### Use the OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8080/v1",   # or your internal LB hostname
    api_key="your-strong-api-key-1",
)

response = client.chat.completions.create(
    model="google/gemma-2-9b-it",
    messages=[{"role": "user", "content": "Explain PagedAttention in one sentence."}],
)
print(response.choices[0].message.content)
```

---

## Step 13 — Access Grafana dashboards

```bash
# Get the Grafana admin password
kubectl -n monitoring get secret kube-prom-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Port-forward Grafana
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
```

Open http://localhost:3000 — login with `admin` / password from above.

Navigate to **Dashboards → vLLM Inference** to see:
- Time to first token (P50/P95/P99)
- End-to-end latency
- Tokens/second per pod
- Queue depth (`num_requests_waiting`)
- GPU memory and utilization
- Requests per second by status

---

## Step 14 — Run a load test (optional)

```bash
make load-test
# Opens Locust UI at http://localhost:8089
# Set host to http://localhost:8080 (if port-forwarding)
# Set number of users and spawn rate, then start
```

Watch the HPA react to queue depth:

```bash
kubectl -n vllm get hpa -w
```

When `num_requests_waiting` exceeds 5, the HPA requests additional replicas (up to 4). The GPU autoscaler provisions a new node (~2 minutes), then the new pod downloads from the already-populated HF cache if using a PVC, or re-downloads if using emptyDir.

---

## Step 15 — Validate security posture

```bash
# Run in-cluster security checks (requires kubectl context)
pytest tests/integration/test_security.py -v
```

Checks:
- vLLM Service is ClusterIP (not LoadBalancer / NodePort)
- All vLLM pods run as non-root
- All containers drop ALL Linux capabilities
- Default-deny NetworkPolicy exists in vllm namespace
- A probe pod from `default` namespace cannot reach vllm (lateral movement blocked)

---

## Step 16 — Deploy Project 3 (RAG)

Project 3 deploys onto the same cluster. Project 1 must be running first.

### 16a. Create Qdrant + RAG secrets in Secret Manager

```bash
# Qdrant API key (used by Qdrant server and all RAG clients)
openssl rand -hex 32 | gcloud secrets create qdrant-api-key --data-file=-

# RAG API keys (end-user keys for the /query endpoint)
cat > /tmp/rag-keys.txt <<EOF
rag-strong-key-1
rag-strong-key-2
EOF
gcloud secrets create rag-api-keys --data-file=/tmp/rag-keys.txt
rm /tmp/rag-keys.txt
```

### 16b. Re-apply Terraform to create RAG buckets + IAM

```bash
# RAG is enabled by default (enable_rag = true in variables.tf)
make apply
```

This creates:
- `gs://${PROJECT_ID}-rag-docs` — documents go here
- `gs://${PROJECT_ID}-qdrant-snapshots` — Qdrant backups (30-day lifecycle)
- 4 GCP service accounts with Workload Identity bindings already in place

### 16c. Build and push the three new images

```bash
export REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/vllm-platform"

docker build -t ${REGISTRY}/embeddings:0.1.0 docker/embeddings/
docker push ${REGISTRY}/embeddings:0.1.0

docker build -t ${REGISTRY}/query-api:0.1.0 docker/query-api/
docker push ${REGISTRY}/query-api:0.1.0

docker build -t ${REGISTRY}/ingestion:0.1.0 docker/ingestion/
docker push ${REGISTRY}/ingestion:0.1.0
```

### 16d. Deploy the RAG tier

```bash
make deploy-rag

# Watch the rollouts
kubectl -n qdrant get pods -w     # 3 replicas, qdrant-0/1/2
kubectl -n rag get pods -w        # embeddings, query-api, eventual ingestion jobs
```

### 16e. Upload a document and query

```bash
# Drop a PDF into the bucket
gsutil cp ~/Downloads/sample.pdf gs://${PROJECT_ID}-rag-docs/

# Trigger ingestion immediately (or wait for the 5-min CronJob)
kubectl -n rag create job --from=cronjob/ingestion ingest-now
kubectl -n rag logs job/ingest-now -f

# Query via port-forward
kubectl -n rag port-forward svc/query-api 18080:80 &
curl -sX POST http://localhost:18080/query \
  -H "X-API-Key: rag-strong-key-1" \
  -H "Content-Type: application/json" \
  -d '{"query": "Summarize the main points"}' | jq
```

### 16f. End-to-end smoke test

```bash
export RAG_API_KEY="rag-strong-key-1"
make rag-smoke-test
```

Uploads a synthetic doc, ingests it, queries, asserts the answer cites it.

### 16g. Verify Qdrant HA

```bash
# Should see qdrant-0, qdrant-1, qdrant-2 all Running
kubectl -n qdrant get pods

# PDB requires 2 of 3 to remain available
kubectl -n qdrant get pdb

# Backup CronJob exists and schedule is correct
kubectl -n qdrant get cronjobs
```

### 16h. Verify the RAG observability stack

```bash
# ServiceMonitors registered
kubectl -n monitoring get servicemonitor query-api embeddings

# Alerts loaded
kubectl -n monitoring get prometheusrule rag-rules

# In Grafana → Explore → query: rag:query_latency_p99
```

---

## Step 17 — Set up TLS / internal hostname (production)

For a real deployment inside a VPC, update the ingress hostname:

```bash
# Edit kubernetes/gateway/ingress.yaml and certificate.yaml
# Replace "llm.internal.example.com" with your actual internal domain

# Create a Cloud DNS zone for your domain (if not exists)
gcloud dns managed-zones create internal-zone \
  --dns-name="internal.example.com." \
  --visibility=private \
  --networks=vllm-platform-vpc

# After cert-manager issues the cert (~2 minutes with DNS-01):
kubectl -n gateway get certificate vllm-tls
# Should show READY=True
```

---

## Cost controls

The cluster has built-in cost guardrails:

| Control | Effect |
|---|---|
| GPU pool `min_nodes=0` | No GPU cost when idle |
| Spot instances on both pools | 60–70% off node cost |
| Scheduled CronJob (22:00–09:00 IST) | ~60% additional saving on dev clusters |
| HPA `maxReplicas: 4` | Bounds peak GPU spend |
| `make destroy` GPU-first ordering | Stops GPU billing immediately |

### Estimated monthly cost (dev, off-hours usage ~8h/day)

| Component | Cost |
|---|---|
| GPU node (spot L4, 8h/day × 22 days) | ~$100 |
| CPU nodes (spot e2-standard-4 × 2) | ~$40 |
| Networking, storage, monitoring | ~$30–50 |
| **Total** | **~$170–200/month** |

---

## Teardown

```bash
make destroy
```

This:
1. Scales GPU pool to 0 first (stops GPU billing immediately)
2. Deletes all K8s workloads
3. Runs `terraform destroy` (removes GKE, VPC, IAM, buckets)

To only stop GPU billing without full teardown:

```bash
gcloud container clusters resize vllm-platform \
  --node-pool=gpu-pool \
  --region=${REGION} \
  --num-nodes=0
```

---

## Troubleshooting quick reference

| Symptom | First check |
|---|---|
| vLLM pod stuck `Pending` | `kubectl -n vllm describe pod <name>` — GPU node not yet provisioned? |
| vLLM `CrashLoopBackOff` | `kubectl -n vllm logs deployment/vllm --previous` — usually HF token or CUDA OOM |
| Gateway 401 on valid key | `kubectl -n gateway get externalsecret` — ESO may not have synced yet |
| HPA not scaling | `kubectl -n vllm describe hpa vllm` — check Prometheus Adapter is running |
| Model download > 15 min | Probably HF token missing/expired — check `kubectl -n vllm get secret hf-token` |
| `make apply` fails on GPU quota | Request L4 quota increase — link printed by bootstrap.sh |

Full runbook: `docs/runbook.md`

---

## Folder structure reference

```
.
├── terraform/              # Infrastructure-as-code (GKE, VPC, addons)
│   └── modules/
│       ├── network/        # VPC, Cloud NAT, firewall
│       ├── gke/            # Cluster, Workload Identity
│       ├── node-pools/     # CPU + GPU pools
│       └── platform/       # Prometheus, cert-manager, ESO
├── kubernetes/
│   ├── vllm/               # vLLM Deployment, HPA, NetworkPolicy, ESO
│   ├── gateway/            # FastAPI proxy, Ingress, TLS, NetworkPolicy
│   ├── observability/      # ServiceMonitors, alerts, Grafana dashboard
│   └── cost-controls/      # Scheduled scale-to-zero CronJobs
├── docker/apikey-gateway/  # Gateway source (main.py, Dockerfile)
├── scripts/                # bootstrap.sh, deploy.sh, smoke-test.sh
├── tests/integration/      # Gateway unit tests + in-cluster security tests
└── docs/                   # architecture.md, runbook.md, security.md, cost.md
```
