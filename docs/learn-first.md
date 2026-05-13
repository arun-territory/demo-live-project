# Learn First — Before You Touch Any Code

If you've never built AI infrastructure before, this page is the only thing you read for the next 2–3 hours. Don't go to the project folders yet. Don't `git clone` and start typing. **Read this first.**

Every word in these projects shows up below, explained in plain English.

---

## The big picture in one paragraph

You're going to build a **private ChatGPT** that runs on Google Cloud — a server that takes questions and gives back AI-generated answers, but the server belongs to you (not OpenAI). Then you'll add a **document-search feature** on top of it, so a user can upload PDFs and ask questions about them. The whole thing runs inside a private network, scales up when busy, scales to zero when not needed (to save money), and has dashboards showing how it's behaving.

---

## The 10 words you MUST know

### 1. **Kubernetes** (also called "k8s")

A system that runs your programs across many computers. Think of it like an air traffic controller — it decides which plane (your program) lands on which runway (which computer), and if one runway closes (a computer crashes), it sends the plane to a different runway automatically.

**Why we use it:** When your AI gets popular, you need 4 GPUs instead of 1. Kubernetes makes that easy.

---

### 2. **GKE** (Google Kubernetes Engine)

Kubernetes running on Google Cloud. You don't install it yourself — Google manages it for you. You just say "I want a Kubernetes cluster" and they create one.

---

### 3. **Pod**

The smallest thing in Kubernetes. A pod = one running program (sometimes a few helper programs alongside).

Example: "the vLLM pod" = the program that's actually answering AI questions.

---

### 4. **Container** (and Docker)

A container is a frozen, packaged version of your program that runs the same way on any computer. Like a TV dinner — you can heat it up on any oven and it tastes the same.

Docker is the tool that builds and runs containers. A pod runs one or more containers.

---

### 5. **GPU** (and L4, A100, H100)

A Graphics Processing Unit. Originally made for video games, turns out it's also amazing at math, which is what AI needs.

- **L4** — small GPU, ~$0.28/hour on spot. Good for 9B-parameter models. **This is what we use.**
- **A100** — big GPU, ~$3/hour. For 70B models.
- **H100** — biggest, ~$8/hour. For 405B models.

---

### 6. **LLM** (Large Language Model) and **Gemma 2 9B**

LLM = the AI model. Like the "brain" that knows how to talk.

**Gemma 2 9B** = Google's open-source LLM. The "9B" means 9 billion parameters (~18 GB in memory). Fits in an L4. We use it because:
- The license is open (no signup required)
- The quality is decent
- It fits the GPU we picked

Other famous LLMs: GPT-4 (OpenAI's, closed), Llama 3 (Meta's, requires signup), Mistral, Claude (Anthropic's).

---

### 7. **vLLM**

A program that **runs an LLM efficiently on a GPU**. Without vLLM, you'd write your own code and serve maybe 5 requests/second. With vLLM, the same GPU serves 250.

It does this through a trick called **PagedAttention** (think of it as smart memory management). You don't need to understand the trick — just know that vLLM is the engine, and Gemma is the fuel.

vLLM exposes an OpenAI-compatible API. That means any code written for ChatGPT works with vLLM by changing one line (the URL).

---

### 8. **RAG** (Retrieval Augmented Generation)

The fancy name for **Project 3**. It just means:

> **Before asking the AI to answer, first find the relevant pages in some documents, then ask the AI using only those pages.**

Without RAG: "What is our refund policy?" → AI guesses or hallucinates.

With RAG: We first search your PDFs, find 3 chunks about refunds, give them to the AI, and say "answer using only this." Result: factually grounded answers with citations.

---

### 9. **Vector / Embedding**

A vector is a list of numbers like `[0.12, -0.34, 0.55, ..., 0.08]` — 384 numbers long in our case.

An **embedding** is a vector that represents the *meaning* of a piece of text. Two pieces of text with similar meaning will have similar vectors (even if they use different words).

Example:
- "How do I get my money back?" → `[0.4, 0.1, -0.2, ...]`
- "Refund policy" → `[0.39, 0.11, -0.21, ...]`

They're close. So if a user types the first one, we can find documents containing the second one.

We use a model called **all-MiniLM-L6-v2** to make these vectors. It runs on a regular CPU (no GPU needed).

---

### 10. **Qdrant** (and "vector database")

A database designed to store vectors and quickly answer "find me the 5 closest vectors to this one." Like Google Search, but searching by meaning instead of words.

When you query Project 3, Qdrant is the thing that finds the relevant chunks in your documents.

---

## Bonus words you'll see

### **Terraform**

A tool that builds cloud infrastructure (VPCs, clusters, buckets) by reading text files. Instead of clicking 47 buttons in the Google Cloud console, you write `resource "google_container_cluster" "main" { ... }` once and run `terraform apply`. Same result, reproducible, in git.

### **Helm**

A package manager for Kubernetes. Like `apt install nginx` on Linux, but `helm install prometheus` on Kubernetes.

### **HPA** (Horizontal Pod Autoscaler)

The thing that says "we have too many requests waiting — add 2 more pods." It looks at a metric and decides whether to scale up or down.

### **Cluster Autoscaler**

The thing that says "we need more pods than the current computers can hold — add another computer." Works together with HPA.

### **VPC** (Virtual Private Cloud)

Your private network in the cloud. Nobody else can see traffic inside it. Like having a private internet just for your company.

### **Prometheus + Grafana**

Prometheus collects metrics every 15 seconds (CPU, latency, errors, GPU memory). Grafana draws pretty charts of those metrics. You need both.

### **Workload Identity**

A way for Kubernetes pods to access GCP services (like Secret Manager) **without storing passwords or keys**. The pod says "I am pod X in namespace Y" and GCP trusts the cluster's word for it.

### **External Secrets Operator (ESO)**

A tool that copies secrets from GCP Secret Manager into Kubernetes Secrets automatically. So you never have to put secrets in your YAML files.

### **NetworkPolicy**

Rules that say "pod A is allowed to talk to pod B but not pod C." Default-deny means "nothing can talk to anything unless explicitly allowed."

### **Spot instance** (also "preemptible")

A cheaper VM that can disappear at any time. 60–70% off normal price. Good for stateless work. We use spot for both CPU and GPU pools.

### **Cloud NAT**

Lets your private cluster reach the public internet **for outbound traffic only**. We need this because vLLM downloads the model from HuggingFace once at startup.

### **cert-manager**

Auto-renews HTTPS certificates from Let's Encrypt. So your endpoint has `https://` without you ever touching certificate files.

### **API key**

A long random string in a request header (like `X-API-Key: abc123...`) that proves the caller is authorized.

### **CronJob**

A Kubernetes thing that runs a job on a schedule. Like Unix cron. We use one to scan the docs bucket every 5 minutes.

### **StatefulSet**

A Kubernetes thing for pods that need stable storage (like a database). Each pod gets the same disk back after a restart. Qdrant is a StatefulSet.

---

## The 3 things that confuse beginners (and the truth)

### Confusion 1: "I have to learn AI/ML to do this."

**Truth: No.** You're building the *infrastructure*. You're not training the AI. The AI (Gemma 2) is already trained — you're just running it. This is a **DevOps / Platform Engineering** project, with the word "GenAI" in it. That's why it pays 40+ LPA.

### Confusion 2: "There are too many tools."

**Truth: Yes there are.** Don't try to learn them all at once. Learn one when you encounter it. Use the table below.

### Confusion 3: "I don't know where to start."

**Truth:** Start at the top of the README. Follow the 3 numbered steps in order. Don't open Project 3 until Project 1 is running. Don't open `kubernetes/` until you've read the README in that project folder.

---

## A 1-week plan to get unstuck

| Day | What to do |
|---|---|
| **Day 1** | Read this whole page. Slowly. Look up YouTube videos for any word you still don't get. |
| **Day 2** | Watch one video each: (a) "Kubernetes in 100 seconds" (Fireship), (b) "What is vLLM" (Anyscale talk on YouTube), (c) "What is RAG" (any 5-min explainer) |
| **Day 3** | Create a Google Cloud account. Run `gcloud auth login`. Don't deploy anything yet. |
| **Day 4** | Read `shared-infra/README.md`. Then run `make apply` in shared-infra. Watch it build. |
| **Day 5** | Read `project-1-inference/README.md`. Don't deploy yet — just read. |
| **Day 6** | Deploy Project 1. Hit it with `make smoke-test`. See it return a response. Take a screenshot. |
| **Day 7** | Open Grafana. Run a load test. Watch the GPU pool scale. Be impressed with yourself. |

After Day 7 you've done **Project 1**. That alone is a complete portfolio piece. **Stop and ship it.** Don't rush into Project 3.

---

## The right mindset

You will:
- Feel overwhelmed on Day 1
- Feel less overwhelmed by Day 4
- Get stuck somewhere around Day 5–6
- Google the error
- Find the answer
- Move on

That's the entire job of a platform engineer. Nobody is born knowing this stuff. The people who get the 60 LPA roles are just the ones who didn't give up at Day 5.

---

Once you've read this, go open [`shared-infra/README.md`](../shared-infra/README.md).
