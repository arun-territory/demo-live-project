# api-gateway

Edge service for clients. Validates JWTs, applies an in-memory rate limit,
and proxies authenticated requests to the backend services.

## Endpoints
- `GET  /healthz`
- `GET  /readyz`
- `POST /auth/login` — `{ email }` returns `{ token }` (demo only)
- `* /api/accounts/**`     → `account-service` (auth required)
- `* /api/transactions/**` → `transaction-service` (auth required)

## Env
| Var | Default |
|---|---|
| `PORT` | `8080` |
| `JWT_SECRET` | `dev-secret-change-me` |
| `JWT_TTL_SECONDS` | `3600` |
| `RATE_WINDOW_MS` | `60000` |
| `RATE_MAX` | `120` |
| `ACCOUNT_SERVICE_URL` | `http://account-service:8080` |
| `TRANSACTION_SERVICE_URL` | `http://transaction-service:8080` |

## Notes
- The login endpoint is a stub. In production, swap for an IdP (Identity
  Platform, Auth0, Keycloak) and verify tokens via JWKS instead of a shared
  secret.
- Rate limit is in-memory per pod. Use Redis or Istio rate limiting for
  cluster-wide accuracy.
