const express = require('express');
const { pool, init } = require('./db');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 8080);

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.get('/readyz', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ready' });
  } catch (err) {
    res.status(503).json({ status: 'not-ready', error: err.message });
  }
});

app.post('/accounts', async (req, res) => {
  const { owner_name, email } = req.body || {};
  if (!owner_name || !email) {
    return res.status(400).json({ error: 'owner_name and email are required' });
  }
  try {
    const result = await pool.query(
      'INSERT INTO accounts (owner_name, email) VALUES ($1, $2) RETURNING *',
      [owner_name, email]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    if (err.code === '23505') {
      return res.status(409).json({ error: 'email already exists' });
    }
    res.status(500).json({ error: err.message });
  }
});

app.get('/accounts/:id', async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM accounts WHERE id = $1', [req.params.id]);
  if (rows.length === 0) return res.status(404).json({ error: 'not found' });
  res.json(rows[0]);
});

app.get('/accounts', async (_req, res) => {
  const { rows } = await pool.query('SELECT * FROM accounts ORDER BY id');
  res.json(rows);
});

app.post('/accounts/:id/credit', async (req, res) => {
  const amount = Number(req.body?.amount_cents);
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amount_cents must be a positive number' });
  }
  const { rows } = await pool.query(
    'UPDATE accounts SET balance_cents = balance_cents + $1 WHERE id = $2 RETURNING *',
    [amount, req.params.id]
  );
  if (rows.length === 0) return res.status(404).json({ error: 'not found' });
  res.json(rows[0]);
});

app.post('/accounts/:id/debit', async (req, res) => {
  const amount = Number(req.body?.amount_cents);
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'amount_cents must be a positive number' });
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      'SELECT balance_cents FROM accounts WHERE id = $1 FOR UPDATE',
      [req.params.id]
    );
    if (rows.length === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'not found' });
    }
    if (Number(rows[0].balance_cents) < amount) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: 'insufficient funds' });
    }
    const updated = await client.query(
      'UPDATE accounts SET balance_cents = balance_cents - $1 WHERE id = $2 RETURNING *',
      [amount, req.params.id]
    );
    await client.query('COMMIT');
    res.json(updated.rows[0]);
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(500).json({ error: err.message });
  } finally {
    client.release();
  }
});

async function main() {
  let attempts = 0;
  while (attempts < 30) {
    try {
      await init();
      break;
    } catch (err) {
      attempts++;
      console.error(`DB init failed (attempt ${attempts}): ${err.message}`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  app.listen(PORT, () => console.log(`account-service listening on ${PORT}`));
}

main();
