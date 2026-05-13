# Private GenAI Platform on GKE

**Two separate projects that share one Kubernetes cluster.**

If you've never built anything in AI before, **stop and read [`docs/learn-first.md`](docs/learn-first.md) before opening any code**. It explains every word you're about to see in plain English.

---

## What's here

| Folder | What it does | When to use it |
|---|---|---|
| **`shared-infra/`** | Builds the empty Kubernetes cluster on GCP | **First**. Run once. |
| **`project-1-inference/`** | A private ChatGPT-like API (vLLM serving Gemma 2 9B) | **Second**. Build this. Ship it. Get a job. |
| **`project-3-rag/`** | Document Q&A with citations (RAG on top of Project 1) | **Third**. Only after Project 1 works. |

Each project has its own **README**, its own **Makefile**, its own **scripts**. They don't share files. You can build, deploy, and destroy each one separately.

## The order you must follow

```
   ┌───────────────────┐
   │ 1. shared-infra/  │   The land + empty warehouse
   │    make apply     │   (~15 min, ~$170/month idle)
   └─────────┬─────────┘
             │
             ▼
   ┌─────────────────────────┐
   │ 2. project-1-inference/  │   The AI (the kitchen)
   │    make deploy           │   (~15 min for model download)
   └─────────┬───────────────┘
             │
             ▼  (you can stop here — Project 1 is a complete project on its own)
             │
             ▼
   ┌─────────────────────────┐
   │ 3. project-3-rag/       │   Documents Q&A (the waiter)
   │    make deploy          │   Uses Project 1 under the hood
   └─────────────────────────┘
```

## "Where do I start?" — exact commands

```bash
# 0. One-time GCP setup (5 min)
export PROJECT_ID=your-gcp-project-id
export REGION=us-central1
bash scripts/bootstrap.sh

# 1. Build the empty cluster (15 min)
cd shared-infra
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform/terraform.tfvars — set project_id
make apply

# 2. Build Project 1 — read its README first
cd ../project-1-inference
cat README.md          # ← read this fully
# follow its steps to build/push images, create secrets, deploy

# (pause for 1–2 weeks. Use Project 1. Write a blog post. Apply to jobs.)

# 3. Then come back for Project 3 — read its README first
cd ../project-3-rag
cat README.md          # ← read this fully
```

## Documentation map

If you don't know what something means, find it here:

| Topic | File |
|---|---|
| **Words you don't know yet** | [`docs/learn-first.md`](docs/learn-first.md) ← **start here** |
| Project 1 — what it is, how to deploy | [`project-1-inference/README.md`](project-1-inference/README.md) |
| Project 3 — what it is, how to deploy | [`project-3-rag/README.md`](project-3-rag/README.md) |
| Deep architecture (for the engineer in you) | [`ARCHITECTURE.md`](ARCHITECTURE.md) and [`docs/architecture.md`](docs/architecture.md) |
| Step-by-step end-to-end implementation (combined) | [`implementation.md`](implementation.md) |
| Diagrams of every flow | [`docs/diagrams.md`](docs/diagrams.md) |
| When things break (oncall) | [`docs/runbook.md`](docs/runbook.md) |
| Security threat model | [`docs/security.md`](docs/security.md) |
| Cost breakdowns | [`docs/cost.md`](docs/cost.md) |
| Project 3 deep dive | [`project-3-rag/rag.md`](project-3-rag/rag.md) |

## What this whole thing is

> A private, self-hosted Generative AI Platform on Kubernetes — Inference + RAG, with enterprise-grade security, observability, and cost controls.

Read that sentence again. **That's your resume headline.** It's what makes companies pay 40–60 LPA for the engineer who built it.

## Cost summary

| State | Cost / month |
|---|---|
| Nothing deployed | $0 |
| `shared-infra` only (cluster idle) | ~$170 |
| + Project 1 (GPU 8h/day) | +$80 = ~$250 |
| + Project 3 (everything running) | +$25 = ~$275 |

To stop billing fast: scale GPU pool to zero or `make destroy` in `shared-infra/`.

## License

Apache 2.0
