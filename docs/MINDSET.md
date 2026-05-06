# Platform Engineer Mindset — Daily Driver

> Support sees symptoms. Platform builds the immune system.
> Read this every morning. Pick one section, apply it to one file you touched today.

---

## The 3 Questions — ask them about every file

1. **Contract** — what inputs does it need, what does it expose?
2. **Failure mode** — when it breaks, what's the log line, and how does it self-heal?
3. **Portability** — what's standard vs. cloud-locked? Could I move it in a week?

---

## Per-file checklist

### 📂 Source code
- [ ] Config from env vars, never hardcoded
- [ ] Secrets injected at runtime, never in image
- [ ] `/health` (liveness) + `/ready` (readiness) exist and mean different things
- [ ] Stateless — kill the pod, lose nothing

### 🐳 Dockerfile
- [ ] Multi-stage build, final image < 200 MB
- [ ] Runs as non-root (`USER 1000`)
- [ ] Pinned base image digest, no `:latest`
- [ ] No `apt-get` at runtime — image is fully self-contained

### 🏗️ Terraform
- [ ] IAM is least privilege — every role defended in review
- [ ] State is remote, encrypted (CMEK), versioned
- [ ] Same module runs dev/uat/prod — only `tfvars` differ
- [ ] `prevent_destroy` on anything that holds data

### ☸️ Kubernetes / Helm
- [ ] CPU + memory `requests` and `limits` set
- [ ] HPA + PDB + topology spread defined
- [ ] NetworkPolicy default-deny in the namespace
- [ ] `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, drop ALL caps

---

## 4 core principles (memorize)

| Principle | One-line test |
|-----------|--------------|
| **Statelessness** | Can I `kubectl delete pod` without losing data? |
| **Observability** | Can I diagnose using only logs + metrics + traces? |
| **Idempotency** | Does running it twice end in the same state? |
| **GitOps** | If it's not in git, it doesn't exist. |

---

## Self-test (no peeking — answer aloud)

### Beginner — you should know these in week 1
1. What's the difference between liveness and readiness probes? Give a scenario where one passes and the other fails.
2. Why does a container run as a non-root user? What happens if it doesn't?
3. What does `terraform plan` do that `terraform apply` doesn't?
4. Why is `:latest` an anti-pattern in Kubernetes manifests?
5. A pod is `CrashLoopBackOff`. Name three commands you'd run, in order.

### Intermediate — you should know these in month 1
6. What is Workload Identity and why is it better than mounting a service account JSON key?
7. Explain the GitOps reconciliation loop. What happens if I `kubectl edit` a resource ArgoCD manages?
8. Why do we put a `PodDisruptionBudget` on a service that has an HPA?
9. What's the blast radius of a leaked CI service account key in our setup? What limits it?
10. CMEK vs Google-managed encryption — when does the difference actually matter?

### Advanced — you should be able to defend these in design review
11. Walk through how a request from the internet reaches `account-service`. Name every hop and what enforces security at each one.
12. Cloud SQL primary fails at 03:00. What happens, in what order, and what's the customer-visible impact?
13. Someone pushes an image with a HIGH CVE. Name every gate that should stop it before it runs in dev.
14. How would you onboard a new microservice in under a day? List the artifacts that must exist before traffic flows.
15. Our SLO is 99.9% availability. We've burned 80% of the monthly error budget on day 10. What do you do?

### Trap questions — these expose weak mental models
16. Why is `kubectl apply` not idempotent in all cases? (Hint: think about field ownership.)
17. If both Terraform and ArgoCD manage Kubernetes resources, who owns what — and how do you decide?
18. We enabled Binary Authorization in `DRYRUN` mode. What does that actually prevent? What does it not?
19. A Slack alert fires for high p99 latency, but Grafana shows latency is fine. Name three reasons this can happen.
20. We have backups. Are we sure we can restore? How do we know?

---

## Daily ritual

**Morning (5 min):** read this file. Pick one checklist item.
**During work:** apply it to one PR or file you touch.
**End of day (2 min):** answer one question above. If you stumbled, mark it and revisit tomorrow.

After 30 days, you don't read this — you live it.
