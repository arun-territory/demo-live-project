# demo-live-project — FinDevOps microservices

A 5-service fintech demo, designed to be deployed via the GitOps pipeline
described in `docs/architecture.md` (Terraform + GKE + ASM + ArgoCD).
This repo contains the application code; infrastructure and GitOps
manifests live in their own repos.

## Services

| Service | Port (host) | Purpose | State |
|---|---|---|---|
| `frontend` | `3000` | Static UI (Nginx) | stateless |
| `api-gateway` | `8080` | JWT auth, rate limit, routing | stateless |
| `account-service` | `8081` | Accounts and balances (Postgres) | **stateful** |
| `transaction-service` | `8082` | Transfers + event publishing | stateless |
| `notification-service` | `8083` | Event consumer + dispatch | stateless |
| `postgres` | `5432` | Local database | (local only) |

## Run locally

```bash
docker compose up --build
```

Then open <http://localhost:3000>.

### Smoke test from the CLI

```bash
# 1. Get a token
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"alice@example.com"}' | jq -r .token)

# 2. Create two accounts
curl -s -X POST http://localhost:8080/api/accounts \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"owner_name":"Alice","email":"alice@example.com"}'
curl -s -X POST http://localhost:8080/api/accounts \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"owner_name":"Bob","email":"bob@example.com"}'

# 3. Deposit into account 1
curl -s -X POST http://localhost:8080/api/transactions/deposit \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"account_id":1,"amount_cents":100000}'

# 4. Transfer 1->2
curl -s -X POST http://localhost:8080/api/transactions/transfer \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"from_account_id":1,"to_account_id":2,"amount_cents":2500}'

# 5. Inspect notifications
curl -s http://localhost:8083/notifications | jq
```

### Stop and clean up

```bash
docker compose down -v
```

## Architecture (high-level)

```
browser ──> frontend (nginx)
                │  /api/*
                ▼
           api-gateway ──auth+routing──┐
                                       ├──> account-service ──> postgres
                                       └──> transaction-service ──> notification-service
                                                                       (HTTP locally;
                                                                        Pub/Sub in GCP)
```

## Local vs. GCP

| Concern | Local | GCP |
|---|---|---|
| DB | Postgres container | Cloud SQL (private IP, HA) |
| Eventing | HTTP POST | Pub/Sub |
| Auth to GCP | n/a | Workload Identity |
| Secrets | env vars | Secret Manager |
| Ingress | Nginx | Istio Ingress Gateway (mTLS) |
| Service-to-service | plain HTTP | mTLS via ASM |

## Next phases

See the build plan for Phase 5+ (Helm charts, GitHub Actions CI/CD,
GitOps manifests, ArgoCD, Terraform infra).
