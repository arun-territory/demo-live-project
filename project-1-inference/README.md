# Project 1 — Private LLM Inference

## What is this, in plain English?

You know how ChatGPT works? You send it a question, it sends back an answer.

**This project is the same thing — but the AI lives inside your own server, not at OpenAI.**

The benefit: your data never leaves your network. Hospitals, banks, and law firms can finally use LLMs because the customer's data stays in their own cloud account.

## What it actually does

```
   You type a question
        │
        ▼
   ┌────────────────────────┐
   │ Your app calls         │   POST /v1/chat/completions
   │ https://llm.internal/  │   {"messages": [...]}
   └──────────┬─────────────┘
              │
              ▼
   ┌────────────────────────┐
   │ A small "doorman" app  │   ← checks your API key
   │ (gateway)              │     rejects bad keys
   └──────────┬─────────────┘
              │ valid key — forward
              ▼
   ┌────────────────────────┐
   │ vLLM — the AI engine   │   ← runs on a GPU
   │ running Gemma 2 9B     │     generates the answer
   └──────────┬─────────────┘
              │
              ▼
   ┌────────────────────────┐
   │ Answer flows back      │
   │ to your app            │
   └────────────────────────┘
```

The whole thing speaks the same language as OpenAI's API, so any code that works with OpenAI (the `openai` Python library, LangChain, etc.) works here with one line changed (the URL).

## Two main parts

### 1. The "doorman" (`docker/apikey-gateway/`)

A tiny ~110-line program written in Python. Its only job:
- Check the API key in the request header
- If valid, pass the request through to vLLM
- If invalid, reject with 401

Why we need a doorman: vLLM doesn't have built-in authentication. So we put this in front. **Defense in depth.**

### 2. The "AI engine" (`kubernetes/vllm/`)

This is **vLLM**, an open-source tool by UC Berkeley that runs LLMs efficiently. It loads Google's **Gemma 2 9B** model into the GPU's memory and answers requests.

Why Gemma 2 9B?
- Open license (no signup, no click-through)
- Decent quality
- Fits in an NVIDIA L4 GPU (24 GB VRAM)

## What you need before starting

1. **Shared infra must be deployed first.** Go to `../shared-infra/` and run `make apply` if you haven't already.
2. **A HuggingFace account + token** (free) — needed to download the model. Get one at https://huggingface.co/settings/tokens
3. **You must request access to Gemma 2** on its model page (instant approval).

## Deploy in 5 steps

### Step 1: Store your secrets in GCP Secret Manager

```bash
# HuggingFace token (so vLLM can download the model)
echo -n "hf_YOUR_TOKEN_HERE" | gcloud secrets create hf-token --data-file=-

# API keys for your app (any random strong strings, one per line)
cat > /tmp/api-keys.txt <<EOF
my-strong-key-1
my-strong-key-2
EOF
gcloud secrets create vllm-api-keys --data-file=/tmp/api-keys.txt
rm /tmp/api-keys.txt
```

### Step 2: Create GCP service accounts (one-time)

```bash
# Two GCP service accounts: one for vLLM, one for the gateway
gcloud iam service-accounts create vllm-runtime --display-name="vLLM Runtime"
gcloud iam service-accounts create gateway-runtime --display-name="Gateway Runtime"

# Both need permission to read secrets
for SA in vllm-runtime gateway-runtime; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
done

# Bind Kubernetes service accounts to GCP service accounts (Workload Identity)
gcloud iam service-accounts add-iam-policy-binding \
  vllm-runtime@$PROJECT_ID.iam.gserviceaccount.com \
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[vllm/vllm-runtime]" \
  --role="roles/iam.workloadIdentityUser"

gcloud iam service-accounts add-iam-policy-binding \
  gateway-runtime@$PROJECT_ID.iam.gserviceaccount.com \
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[gateway/gateway-runtime]" \
  --role="roles/iam.workloadIdentityUser"
```

### Step 3: Build and push the gateway image

```bash
gcloud artifacts repositories create vllm-platform \
  --repository-format=docker --location=$REGION || true
gcloud auth configure-docker $REGION-docker.pkg.dev

export REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/vllm-platform"
docker build -t $REGISTRY/apikey-gateway:0.1.0 docker/apikey-gateway/
docker push $REGISTRY/apikey-gateway:0.1.0
```

### Step 4: Deploy

```bash
export PROJECT_ID=$PROJECT_ID
export REGION=$REGION
export CLUSTER_NAME=dev-genai-inference
export REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/vllm-platform"
make deploy
```

This will take 10–15 minutes because vLLM has to download the Gemma 2 9B model (~18 GB).

### Step 5: Test

```bash
make smoke-test
```

Should print "pong" or a sensible chat response.

## How to use it from your code

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://llm.internal.example.com/v1",
    api_key="my-strong-key-1",
)

response = client.chat.completions.create(
    model="google/gemma-2-9b-it",
    messages=[{"role": "user", "content": "Explain Kubernetes to a 5-year-old"}],
)
print(response.choices[0].message.content)
```

That's it. Your AI now answers without sending data to OpenAI.

## What's inside this folder

```
project-1-inference/
├── README.md           ← you are here
├── Makefile            ← deploy / smoke-test / undeploy / load-test
├── kubernetes/
│   ├── vllm/             ← the AI engine
│   ├── gateway/          ← the doorman
│   ├── observability/    ← Prometheus + Grafana setup for this project
│   └── cost-controls/    ← turns off GPUs at night to save money
├── docker/
│   └── apikey-gateway/   ← source code for the doorman
├── scripts/
│   ├── deploy.sh         ← what `make deploy` runs
│   ├── smoke-test.sh     ← what `make smoke-test` runs
│   └── load-test.py      ← simulate many users
└── tests/
    └── integration/      ← Python tests for the doorman
```

## Tear down

```bash
make undeploy   # delete the workload only (cluster stays up)
```

To delete the cluster too, go to `../shared-infra/` and run `make destroy`.

## Common errors

| You see | What it means | Fix |
|---|---|---|
| Pod stuck in `Pending` | GPU node not yet created | Wait 2–3 minutes (cluster autoscaler is spinning one up) |
| `401 Unauthorized` on model download | HF token wrong or you didn't request Gemma 2 access | Check token, visit huggingface.co/google/gemma-2-9b-it |
| `CrashLoopBackOff` | Usually OOM | See `../docs/runbook.md` |

## How much does this cost?

- Idle (no GPU running): **~$0**
- Active inference (1 GPU running 8h/day): **~$50–80/month** for the GPU
- Add the shared-infra cost (~$170/month) for the total bill

## What I learned by building this

(Once you've built it, write your own list here. This is what you'll talk about in interviews.)
