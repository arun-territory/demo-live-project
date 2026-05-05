// Tiny in-memory token bucket per IP. Replace with Redis-backed limiter
// or Istio rate limiting at the mesh edge in production.
const WINDOW_MS = Number(process.env.RATE_WINDOW_MS || 60_000);
const MAX_REQS = Number(process.env.RATE_MAX || 120);

const buckets = new Map();

function rateLimit(req, res, next) {
  const key = req.ip;
  const now = Date.now();
  const bucket = buckets.get(key) || { count: 0, resetAt: now + WINDOW_MS };
  if (now > bucket.resetAt) {
    bucket.count = 0;
    bucket.resetAt = now + WINDOW_MS;
  }
  bucket.count++;
  buckets.set(key, bucket);
  if (bucket.count > MAX_REQS) {
    return res.status(429).json({ error: 'rate limit exceeded' });
  }
  next();
}

module.exports = { rateLimit };
