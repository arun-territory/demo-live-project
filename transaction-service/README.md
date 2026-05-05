# transaction-service

Stateless. Orchestrates transfers between accounts by calling `account-service`,
and publishes `transaction.completed` / `transaction.failed` events.

## Endpoints
- `GET  /healthz`
- `GET  /readyz`
- `POST /transactions/transfer` — `{ from_account_id, to_account_id, amount_cents }`
- `POST /transactions/deposit`  — `{ account_id, amount_cents }`

## Env
| Var | Default |
|---|---|
| `PORT` | `8080` |
| `ACCOUNT_SERVICE_URL` | `http://account-service:8080` |
| `NOTIFICATION_URL` | `http://notification-service:8080/events` |

## Notes
- Transfer is **not** atomic across services. On credit failure we compensate
  by re-crediting the source account. Production would use a saga / outbox
  pattern with Pub/Sub for durability.
- Local publisher posts events over HTTP. In GCP it should be replaced with
  a Pub/Sub publisher (`@google-cloud/pubsub`).
