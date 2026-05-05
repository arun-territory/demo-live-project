# notification-service

Stateless. Receives transaction events and would dispatch notifications
(email/SMS). Locally it just logs and exposes a recent-events endpoint
so you can verify the flow worked.

## Endpoints
- `GET  /healthz`
- `GET  /readyz`
- `POST /events` — invoked by `transaction-service`
- `GET  /notifications` — last 100 received events (for local inspection)

## Notes
- Local event delivery is HTTP. In GCP, this becomes a Pub/Sub push or pull
  subscription, with the same handler logic.
- Real notification dispatch (SendGrid, Twilio) is left as a TODO; secrets
  would be loaded from Secret Manager via Workload Identity in GCP.
