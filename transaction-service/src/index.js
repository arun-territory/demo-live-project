const express = require('express');
const { publish } = require('./publisher');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 8080);
const ACCOUNT_URL = process.env.ACCOUNT_SERVICE_URL || 'http://account-service:8080';

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.get('/readyz', (_req, res) => res.json({ status: 'ready' }));

async function callAccount(path, body) {
  const res = await fetch(`${ACCOUNT_URL}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, data };
}

// Transfer money between two accounts.
// Body: { from_account_id, to_account_id, amount_cents }
app.post('/transactions/transfer', async (req, res) => {
  const { from_account_id, to_account_id, amount_cents } = req.body || {};
  if (!from_account_id || !to_account_id || !Number.isFinite(Number(amount_cents)) || Number(amount_cents) <= 0) {
    return res.status(400).json({ error: 'from_account_id, to_account_id, and positive amount_cents required' });
  }
  if (from_account_id === to_account_id) {
    return res.status(400).json({ error: 'cannot transfer to same account' });
  }

  const debit = await callAccount(`/accounts/${from_account_id}/debit`, { amount_cents });
  if (!debit.ok) {
    await publish({
      type: 'transaction.failed',
      reason: debit.data?.error || 'debit failed',
      from_account_id,
      to_account_id,
      amount_cents,
      at: new Date().toISOString(),
    });
    return res.status(debit.status).json({ error: debit.data?.error || 'debit failed' });
  }

  const credit = await callAccount(`/accounts/${to_account_id}/credit`, { amount_cents });
  if (!credit.ok) {
    // Compensate: refund the debited account.
    await callAccount(`/accounts/${from_account_id}/credit`, { amount_cents });
    await publish({
      type: 'transaction.failed',
      reason: credit.data?.error || 'credit failed (refunded)',
      from_account_id,
      to_account_id,
      amount_cents,
      at: new Date().toISOString(),
    });
    return res.status(credit.status).json({ error: credit.data?.error || 'credit failed' });
  }

  const event = {
    type: 'transaction.completed',
    from_account_id,
    to_account_id,
    amount_cents,
    at: new Date().toISOString(),
  };
  await publish(event);
  res.status(201).json({ status: 'completed', ...event });
});

// Single-side deposit.
app.post('/transactions/deposit', async (req, res) => {
  const { account_id, amount_cents } = req.body || {};
  if (!account_id || !Number.isFinite(Number(amount_cents)) || Number(amount_cents) <= 0) {
    return res.status(400).json({ error: 'account_id and positive amount_cents required' });
  }
  const credit = await callAccount(`/accounts/${account_id}/credit`, { amount_cents });
  if (!credit.ok) return res.status(credit.status).json(credit.data);
  await publish({ type: 'transaction.completed', account_id, amount_cents, kind: 'deposit', at: new Date().toISOString() });
  res.status(201).json({ status: 'completed', account_id, amount_cents });
});

app.listen(PORT, () => console.log(`transaction-service listening on ${PORT}`));
