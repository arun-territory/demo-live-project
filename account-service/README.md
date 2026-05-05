# account-service

Stateful microservice. Owns accounts and balances. Persists to PostgreSQL.

## Endpoints
- `GET  /healthz` — liveness
- `GET  /readyz` — readiness (checks DB)
- `POST /accounts` — create `{ owner_name, email }`
- `GET  /accounts` — list
- `GET  /accounts/:id` — fetch one
- `POST /accounts/:id/credit` — `{ amount_cents }`
- `POST /accounts/:id/debit` — `{ amount_cents }` (transactional, rejects on insufficient funds)

## Env
| Var | Default |
|---|---|
| `PORT` | `8080` |
| `DB_HOST` | `postgres` |
| `DB_PORT` | `5432` |
| `DB_USER` | `fintech` |
| `DB_PASSWORD` | `fintech` |
| `DB_NAME` | `fintech` |

## Run locally (without Docker)
```
npm install
DB_HOST=localhost npm start
```
