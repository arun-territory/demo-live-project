# Runbook

The top five things that will page you, and how to fix them.

## 1. `VLLMPodDown` — no pods running

**Likely causes**: GPU pool scaled to 0 and autoscaler hasn't reacted; HF token expired; model image pull failure; spot preemption with no replacement.

```bash
# 1. Is the pod scheduled?
kubectl -n vllm get pods -o wide

# 2. If Pending — check why
kubectl -n vllm describe pod <name> | tail -40
# Look for "0/N nodes are available" + the reason (no GPU, taint, etc).

# 3. If no GPU nodes — manually scale up to bypass autoscaler delay
gcloud container clusters resize $CLUSTER_NAME \
  --node-pool=gpu-pool --region=$REGION --num-nodes=1

# 4. If CrashLoopBackOff — check logs
kubectl -n vllm logs deployment/vllm --tail=100
# Common: "OSError: ... can't access gated repo" → HF token issue
```

## 2. `VLLMHighP99Latency` — slow responses

**Quick triage**:

```bash
# Queue depth + tokens/sec — open Grafana → vLLM Inference dashboard
# If queue > 5 and tokens/sec normal → need more replicas. Check HPA:
kubectl -n vllm describe hpa vllm
# If "FailedGetPodsMetric" → Prometheus Adapter issue (see #5)

# If tokens/sec dropped → check GPU utilization
kubectl -n vllm exec deployment/vllm -- nvidia-smi
# GPU util should be > 80% during load. Lower means CPU-side bottleneck —
# probably tokenizer or network. Check apikey-gateway latency too.
```

## 3. `VLLMHighErrorRate` — 5xx from gateway

```bash
# Gateway logs — what's the upstream returning?
kubectl -n gateway logs deployment/apikey-gateway --tail=200 | grep -E '5[0-9]{2}'

# Common: upstream timeouts → vLLM is slow or OOM
kubectl -n vllm logs deployment/vllm --previous --tail=200 | grep -iE 'oom|cuda'

# If "torch.cuda.OutOfMemoryError" — lower --max-model-len or
# --gpu-memory-utilization in deployment.yaml and roll the pod
```

## 4. `GPUMemoryHigh` — VRAM > 90%

This is a config issue, not a load issue (`--gpu-memory-utilization 0.90` is by design — vLLM pre-allocates the KV cache).

If genuinely problematic (OOMs follow):

```bash
# Edit the value down to 0.85 and roll
kubectl -n vllm set env deployment/vllm \
  VLLM_GPU_MEM_UTIL=0.85  # then update args in deployment.yaml and apply
```

For L4 (24GB), 0.90 leaves ~2.4GB for activations — comfortable for 8K context. If you raise `--max-model-len` above 16K, lower GPU memory utilization to 0.80.

## 5. HPA reports "FailedGetPodsMetric: vllm_num_requests_waiting"

Prometheus Adapter isn't returning the metric.

```bash
# Is the adapter up?
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-adapter

# Is the metric registered with the custom-metrics API?
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq

# Is Prometheus actually scraping vLLM?
# Port-forward Prometheus and check Status → Targets for the vllm ServiceMonitor.
kubectl -n monitoring port-forward svc/kube-prom-stack-kube-prometheu-prometheus 9090:9090
# Then open http://localhost:9090/targets — vllm should be UP.

# If DOWN, common cause: ServiceMonitor label mismatch.
# Verify:  kubectl -n monitoring get servicemonitor vllm -o yaml
# `release: kube-prom-stack` must match the Prometheus's serviceMonitorSelector.
```

## 6. Cold-start is slow (>10 minutes)

This is mostly model download time. Options to reduce:

- **Persistent model cache**: Switch the `hf-cache` volume from `emptyDir` to a `PersistentVolumeClaim` (regional SSD). First pod still pays the download; subsequent pods reuse the volume.
- **Bake the model into a custom image**: Build a derivative of `vllm/vllm-openai` with weights pre-copied to `/cache/hf`. Trade image-size (~20GB) for instant startup.

## 7. Stuck "model downloading" with no progress

```bash
kubectl -n vllm logs deployment/vllm --tail=20 -f
# If repeating "401 Client Error: Unauthorized" → HF token bad / missing.
# Verify ESO materialised it:
kubectl -n vllm get secret hf-token -o jsonpath='{.data.token}' | base64 -d | wc -c
# Should be ~40 bytes for a personal access token.
```

## 8. Cost spike

```bash
# What changed?
gcloud billing accounts get-iam-policy <billing-account>
# Open the billing report grouped by service + sku for the last 7 days.

# If GPU spend is the culprit:
gcloud container node-pools describe gpu-pool \
  --cluster=$CLUSTER_NAME --region=$REGION \
  --format="value(autoscaling.maxNodeCount,initialNodeCount)"
# If max is higher than expected → tighten in terraform and `make apply`.

# Emergency stop:
gcloud container clusters resize $CLUSTER_NAME \
  --node-pool=gpu-pool --region=$REGION --num-nodes=0
```
