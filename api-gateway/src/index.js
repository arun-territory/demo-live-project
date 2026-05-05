const express = require('express');
const { issueToken, requireAuth } = require('./auth');
const { rateLimit } = require('./rateLimit');

const app = express();
app.use(express.json());
app.use(rateLimit);

const PORT = Number(process.env.PORT || 8080);
const ACCOUNT_URL = process.env.ACCOUNT_SERVICE_URL || 'http://account-service:8080';
const TRANSACTION_URL = process.env.TRANSACTION_SERVICE_URL || 'http://transaction-service:8080';

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.get('/readyz', (_req, res) => res.json({ status: 'ready' }));

// Demo login. Real impl would verify credentials against an IdP.
// Body: { email }
app.post('/api/auth/login', (req, res) => {
  const { email } = req.body || {};
  if (!email) return res.status(400).json({ error: 'email required' });
  const token = issueToken({ sub: email });
  res.json({ token, expires_in_seconds: Number(process.env.JWT_TTL_SECONDS || 3600) });
});

async function proxy(target, req, res) {
  const url = `${target}${req.originalUrl.replace(/^\/api/, '')}`;
  try {
    const upstream = await fetch(url, {
      method: req.method,
      headers: { 'content-type': 'application/json' },
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : JSON.stringify(req.body || {}),
    });
    const text = await upstream.text();
    res.status(upstream.status);
    const ct = upstream.headers.get('content-type');
    if (ct) res.set('content-type', ct);
    res.send(text);
  } catch (err) {
    res.status(502).json({ error: 'upstream unreachable', detail: err.message });
  }
}

app.use('/api/accounts', requireAuth, (req, res) => proxy(ACCOUNT_URL, req, res));
app.use('/api/transactions', requireAuth, (req, res) => proxy(TRANSACTION_URL, req, res));

app.listen(PORT, () => console.log(`api-gateway listening on ${PORT}`));
