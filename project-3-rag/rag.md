# Project 3 — Private RAG Platform

A production RAG pipeline on the **same** GKE cluster as Project 1. End users
get an OpenAI-style endpoint that answers questions from their private corpus,
without any data leaving the VPC.

## What's in this layer

| Component | Where | Purpose |
|---|---|---|
| **Qdrant** (3-replica StatefulSet) | `kubernetes/qdrant/` | Vector DB with Raft HA |
| **Embeddings service** | `docker/embeddings/` + `kubernetes/rag/embeddings-*` | `all-MiniLM-L6-v2`, CPU-only, 384-dim |
| **Query API** | `docker/query-api/` + `kubernetes/rag/query-api-*` | RAG orchestrator: embed → search → prompt → vLLM |
| **Ingestion** | `docker/ingestion/` + `kubernetes/rag/ingestion-cronjob.yaml` | GCS → chunk → embed → upsert |
| **Backup** | `kubernetes/qdrant/backup-cronjob.yaml` | Snapshots to GCS every 6h |
| **Observability** | `kubernetes/observability/rag-servicemonitor.yaml` | Per-stage latency, error rate, quorum alerts |
| **Terraform** | `terraform/modules/rag/` | GCS buckets, IAM, SAs, optional Pub/Sub |

## Architecture

```
   Client (in-VPC)
        │
        ▼  HTTPS, X-API-Key
   ┌─────────────────────┐
   │ Internal LB (gce)   │
   └──────────┬──────────┘
              │
              ▼
   ┌─────────────────────┐    ┌──────────────────────┐
   │  query-api          │───▶│ embeddings (CPU)     │
   │  (FastAPI, rag ns)  │    │  all-MiniLM-L6-v2    │
   │  - auth             │    └──────────────────────┘
   │  - orchestrate      │
   │  - cite sources     │    ┌──────────────────────┐
   │                     │───▶│ Qdrant (3 replicas,  │
   │                     │    │  Raft, qdrant ns)    │
   │                     │    └──────────┬───────────┘
   │                     │               │ snapshots
   │                     │               ▼
   │                     │    ┌──────────────────────┐
   │                     │    │  gs://*-snapshots    │
   │                     │    └──────────────────────┘
   │                     │
   │                     │───▶┌──────────────────────┐
   │                     │    │ vLLM gateway         │
   │                     │    │ (Project 1)          │
   │                     │    └──────────┬───────────┘
   └─────────────────────┘               │
                                          ▼
                                ┌──────────────────────┐
                                │ vLLM (L4 GPU)        │
                                │ Gemma 2 9B           │
                                └──────────────────────┘

   ┌────────────────┐    ┌──────────────────────────┐
   │ gs://*-docs    │───▶│ ingestion CronJob (5m)   │───▶  Qdrant
   │ (uploads here) │    │ chunk(1000/200) + embed  │
   └────────────────┘    └──────────────────────────┘
```

## Request flow (end-to-end)

```
POST /query   {"query": "...", "top_k": 5}
  │
  ├─ 1. auth: validate X-API-Key against rag-api-keys (file mounted from ESO)
  ├─ 2. embed: POST /embed [query]  → 384-dim vector
  ├─ 3. retrieve: POST qdrant/.../points/search top_k=5
  ├─ 4. build prompt: "Answer using ONLY: [1] ..., [2] ..., ...  Q: ..."
  ├─ 5. generate: POST vllm-gateway /v1/chat/completions
  └─ 6. respond: {answer, citations[]}

Typical latency budget:
  embed       : 10–30 ms
  retrieve    : 5–20 ms
  generate    : 200–2000 ms (depends on output length)
  total p50   : ~300 ms       p99: 2–4 s
```

## Ingestion pipeline

The CronJob runs every 5 minutes:

1. Lists objects in `gs://${PROJECT_ID}-rag-docs/`
2. For each `.txt`/`.md`/`.pdf` file:
   - Compute its md5; skip if unchanged (lookup in `ingestion_state` collection)
   - Download + extract text (pypdf for PDFs)
   - Chunk: 1000-char windows with 200-char overlap
   - Batch-embed via the embeddings service
   - Upsert to Qdrant. Point IDs are deterministic UUIDs of
     `(source_path, chunk_index)` — re-runs upsert, never duplicate

**Bulk backfill:** Drop hundreds of PDFs into the bucket; one CronJob run
will process them all (`activeDeadlineSeconds: 1800` provides a hard stop).

**Switching to event-driven:** Set `enable_event_driven_ingestion = true` in
terraform.tfvars. This creates a Pub/Sub topic with GCS notifications. You
can then add a Pub/Sub consumer Deployment that calls into the same ingestion
logic per-event. The CronJob still handles backfill and missed events.

## High availability

**Qdrant**: 3 replicas with Raft consensus, anti-affinity across hosts,
PDB `minAvailable: 2` (preserves quorum during voluntary disruptions).
Each replica gets its own 20 GiB PVC. A single zone failure takes one
replica down; quorum survives.

**Query API & embeddings**: 2 replicas each, HPAs scale to 10 / 6 on CPU.
Stateless; preemption is fine.

**vLLM**: HPA from Project 1 on `vllm:num_requests_waiting`, scales 1–4 pods.

## Backups & disaster recovery

`qdrant-backup` CronJob every 6h:
1. Lists collections via Qdrant API
2. Creates a snapshot per collection (`POST /collections/{c}/snapshots`)
3. Streams the snapshot to `gs://${PROJECT_ID}-qdrant-snapshots/`
4. Deletes the local snapshot to reclaim disk

GCS lifecycle rule deletes snapshots older than `qdrant_snapshot_retention_days`
(default 30).

**Restore procedure**: see `docs/runbook.md` §RAG.

## Security

- **Network**: NetworkPolicies in both `qdrant` and `rag` namespaces; only
  the `rag` namespace can reach Qdrant, only the LB health-check CIDRs and
  RFC1918 can reach query-api. Qdrant peer traffic is allowed within the
  `qdrant` namespace only.
- **Auth**: query-api accepts `X-API-Key` or `Authorization: Bearer`; keys
  rotate via ESO refresh (file re-read on every request — no restart).
- **Qdrant API key**: enforced server-side; clients (query-api, ingestion,
  backup CronJob) all use the same key from Secret Manager.
- **Pod security**: restricted PSS, non-root UID 1000, read-only root FS
  where possible (query-api, embeddings); ALL caps dropped.
- **Workload Identity**: every K8s SA maps to a least-privileged GCP SA.
  The `rag-ingestion` SA can only read the docs bucket; `qdrant-backup`
  can only write the snapshots bucket.
- **Data residency**: documents and embeddings never leave the VPC.
  vLLM model weights are the only outbound traffic (HF download via NAT).

## Observability

Prometheus scrapes both `query-api` (port 9100) and `embeddings` (port 9100).

Recording rules:
- `rag:query_latency_p99`, `rag:query_latency_p50`
- `rag:retrieve_latency_p99`, `rag:embed_latency_p99`
- `rag:error_rate`

Alerts:
- `RAGHighP99Latency` (>8s, 5m)
- `RAGHighErrorRate` (>5%, 2m)
- `RAGQueryAPIDown`, `RAGEmbeddingsDown` (1–2m)
- `QdrantQuorumLost` (<2 replicas ready, 2m)

## Cost (typical dev)

| Component | Cost |
|---|---|
| Qdrant: 3 × small pods on spot CPU pool | ~$10–15/mo |
| Embeddings + query-api on CPU pool | ~$5–10/mo |
| GCS docs bucket (10 GB) | ~$0.25/mo |
| GCS snapshots bucket (NEARLINE) | ~$0.10/mo per GB stored |
| Total RAG overhead on top of Project 1 | **~$20–30/mo** |

The bulk of cost stays in Project 1 (GPU). RAG adds <10% if you're running
inference at all.

## Deploy

```bash
# After Project 1 is up:
make deploy-rag

# Or deploy everything from scratch:
make apply       # terraform
make deploy      # vllm + gateway + rag
```

## Test

```bash
export RAG_API_KEY="$(gcloud secrets versions access latest --secret=rag-api-keys | head -1)"
make rag-smoke-test
```

End-to-end smoke test:
1. Uploads `falcon.txt` (a 3-line synthetic doc) to the docs bucket
2. Triggers the ingestion Job manually
3. Queries the API, asserts the response cites `falcon.txt`

## Why each design choice

| Decision | Why |
|---|---|
| **Qdrant over Milvus/Weaviate** | Single-binary, simple Helm-free StatefulSet, great defaults, Rust-fast. Milvus needs etcd + MinIO + 4 separate components. |
| **3 replicas, not 1** | Quorum survives a single zone failure during cluster upgrades / spot preemption. |
| **CPU embeddings, not GPU** | MiniLM-L6 throughput on CPU is plenty (>1000 emb/s/pod). Keeping it off the GPU pool means embeddings never preempt inference. |
| **Deterministic point IDs** | Re-running ingestion on the same files is a no-op. Critical for safe retries. |
| **CronJob, not Eventarc (by default)** | One mechanism for new + missed + re-ingestion. Add Pub/Sub later if event latency matters. |
| **Snapshot to GCS, not PV snapshots** | GCS is cheaper, multi-region, and survives the cluster entirely. PV snapshots get deleted with the PVC. |
| **Two API key sets (rag + vllm)** | Compromise of an end-user RAG key doesn't grant direct vLLM access. Defense in depth. |
| **Citations in the response** | Required by every BFSI/legal use case. Lets the user verify the answer. |
