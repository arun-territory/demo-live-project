# Project 3 — Document QA with Citations (RAG)

## What is this, in plain English?

Imagine you upload your company's PDF manuals to a folder. Then you ask: *"What's our refund policy?"* — and get back:

> "Customers can request a refund within 30 days [1]. Refunds are processed in 5–7 business days [2]."
>
> [1] policy.pdf, page 3 — "Customers may return..."
> [2] manual.pdf, page 12 — "Refunds are issued..."

**This is what Project 3 builds.** It's called **RAG** — Retrieval Augmented Generation.

In plain English: instead of the AI making stuff up, we **first find the relevant pages in your documents, then ask the AI to answer using only those pages**, with citations to prove it.

## Why this matters

Generic ChatGPT can hallucinate. RAG can't (or much less), because it's forced to use your documents. This is what every bank, hospital, and law firm wants to build.

## Three things this project does

### 1. Ingestion (the librarian)

When you upload a file to a Google Cloud Storage bucket, a background job:
1. Picks up the file
2. Splits it into ~1000-character chunks
3. Converts each chunk into a "vector" (a math representation that captures meaning) using a model called **all-MiniLM-L6-v2**
4. Stores the chunks + their vectors in a vector database called **Qdrant**

Think of Qdrant as a smart filing cabinet where things filed by **meaning**, not by alphabet.

### 2. Querying (the librarian + the writer)

When you ask a question:
1. Convert your question into a vector too
2. Search Qdrant: "find the 5 chunks closest in meaning to this question"
3. Send those 5 chunks + your question to the LLM (Project 1's vLLM) with the instruction: *"Answer using only this context. Cite sources."*
4. Return the answer + citations

### 3. Storage (Qdrant — the vector database)

Qdrant runs as 3 replicas with consensus (like a small cluster of mini-databases voting on what's true). This way, if one crashes, the others keep serving. Backups go to Google Cloud Storage every 6 hours.

## How it talks to Project 1

```
   You ask: "What's the refund policy?"
        │
        ▼
   ┌─────────────────────────┐
   │ query-api (this project)│
   └──────────┬──────────────┘
              │
              ├─→ embeddings service: "convert this question to a vector"
              │
              ├─→ Qdrant: "find the 5 most-similar chunks"
              │
              ├─→ PROJECT 1's vLLM gateway: "answer using these 5 chunks"
              │     (yes — Project 3 USES Project 1)
              │
              ▼
   You get: {"answer": "...[1][2]", "citations": [...]}
```

**Important: Project 1 must be deployed first.** Project 3 calls into Project 1's gateway to actually generate the text.

## What you need before starting

1. **Shared infra must be deployed** (`../shared-infra/`)
2. **Project 1 must be deployed** (`../project-1-inference/`) — you can verify with `kubectl -n vllm get pods`
3. **A GCP project with billing enabled**

## Deploy in 6 steps

### Step 1: Store secrets in Secret Manager

```bash
# Qdrant API key (so only authorized clients can read/write vectors)
openssl rand -hex 32 | gcloud secrets create qdrant-api-key --data-file=-

# RAG API keys (for clients calling the /query endpoint)
cat > /tmp/rag-keys.txt <<EOF
rag-strong-key-1
rag-strong-key-2
EOF
gcloud secrets create rag-api-keys --data-file=/tmp/rag-keys.txt
rm /tmp/rag-keys.txt
```

### Step 2: Configure the Terraform stack

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set project_id
```

### Step 3: Apply Project 3's infrastructure (~3 minutes)

This is **separate from shared-infra**. It only creates:
- 2 GCS buckets (one for documents you upload, one for backups)
- 4 GCP service accounts with permissions (rag-runtime, rag-ingestion, qdrant-runtime, qdrant-backup)

```bash
make apply
```

### Step 4: Build and push the 3 images

```bash
cd ..   # back to project-3-rag/
make image
```

This builds embeddings, query-api, and ingestion images and pushes them to Artifact Registry.

### Step 5: Deploy to Kubernetes

```bash
make deploy
```

Watch the pods come up:
```bash
kubectl -n qdrant get pods -w     # should show qdrant-0, qdrant-1, qdrant-2
kubectl -n rag    get pods -w     # embeddings, query-api
```

### Step 6: Test with a real document

```bash
# Upload a document
gsutil cp ~/my-policy.pdf gs://$PROJECT_ID-rag-docs/

# Trigger ingestion right now (or wait for the 5-min CronJob)
kubectl -n rag create job --from=cronjob/ingestion ingest-now
kubectl -n rag logs job/ingest-now -f

# Ask a question
export RAG_API_KEY="rag-strong-key-1"
make smoke-test
```

## How to use it from your code

```python
import requests

response = requests.post(
    "https://rag.internal.example.com/query",
    headers={"X-API-Key": "rag-strong-key-1"},
    json={"query": "What is our data retention policy?"},
)
data = response.json()
print(data["answer"])
for c in data["citations"]:
    print(f"  - {c['source']} (chunk {c['chunk_index']}, score {c['score']:.2f})")
```

## What's inside this folder

```
project-3-rag/
├── README.md           ← you are here
├── rag.md              ← deep-dive architecture (the engineer's version)
├── Makefile            ← apply / deploy / smoke-test / image
├── terraform/          ← Project 3's own infrastructure (buckets + IAM)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf
│   ├── providers.tf
│   ├── terraform.tfvars.example
│   └── module/         ← the actual module code
├── kubernetes/
│   ├── qdrant/         ← vector database (3-replica StatefulSet)
│   ├── rag/            ← embeddings + query-api + ingestion CronJob
│   └── observability/  ← Prometheus alerts + recording rules for RAG
├── docker/
│   ├── embeddings/     ← converts text → vector (CPU only)
│   ├── query-api/      ← the orchestrator (FastAPI)
│   └── ingestion/      ← reads GCS → chunks → embeds → stores
├── scripts/
│   ├── deploy.sh
│   └── smoke-test.sh
└── tests/
    └── integration/    ← unit tests for the query-api
```

## Tear down

```bash
# 1. Remove the Kubernetes workloads
kubectl delete namespace rag qdrant

# 2. Destroy Project 3 buckets + IAM
cd terraform
terraform destroy
```

The shared cluster and Project 1 are not touched.

## Common errors

| You see | What it means | Fix |
|---|---|---|
| Empty citations every time | Ingestion CronJob hasn't run yet | Wait 5 min, or `kubectl -n rag create job --from=cronjob/ingestion ingest-now` |
| `503 — keys file not mounted` | ESO hasn't synced the rag-api-keys secret | Wait 5 min, check `kubectl -n rag get externalsecret` |
| `502 upstream error` | Project 1's vLLM gateway is down or unreachable | `kubectl -n gateway get pods` |
| `QdrantQuorumLost` alert | Two Qdrant pods are down | Check anti-affinity / node availability |

## How much does this cost?

On top of Project 1's cost, this adds **~$20–30/month**:
- Qdrant: 3 small CPU pods → ~$10–15
- embeddings + query-api: 2 CPU pods each → ~$5–10
- GCS docs/snapshots → ~$0.50

## What I learned by building this

(Once you've built it, write your own list here. RAG-specific gotchas, prompt engineering decisions, etc.)
