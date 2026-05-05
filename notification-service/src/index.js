const express = require('express');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 8080);
const recent = []; // ring buffer of the last N events for inspection
const MAX_RECENT = 100;

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.get('/readyz', (_req, res) => res.json({ status: 'ready' }));

// Local "subscriber": receives events posted by transaction-service.
// In GCP, replace with a Pub/Sub pull/push subscription.
app.post('/events', (req, res) => {
  const event = req.body || {};
  dispatch(event);
  recent.unshift({ received_at: new Date().toISOString(), event });
  if (recent.length > MAX_RECENT) recent.pop();
  res.status(202).json({ status: 'accepted' });
});

app.get('/notifications', (_req, res) => res.json(recent));

function dispatch(event) {
  // Production would call SendGrid/Mailgun for email or Twilio for SMS.
  // Here we just log so it's visible in `docker compose logs`.
  switch (event.type) {
    case 'transaction.completed':
      console.log(`[NOTIFY] OK    transfer ${JSON.stringify(event)}`);
      break;
    case 'transaction.failed':
      console.log(`[NOTIFY] FAIL  ${event.reason} ${JSON.stringify(event)}`);
      break;
    default:
      console.log(`[NOTIFY] event ${JSON.stringify(event)}`);
  }
}

app.listen(PORT, () => console.log(`notification-service listening on ${PORT}`));
