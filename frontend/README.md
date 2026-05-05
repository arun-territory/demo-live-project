# frontend

Static HTML/JS UI served by Nginx. Talks to `api-gateway` via `/api/*`,
proxied by Nginx so the browser sees a single origin.

## Pages
Single-page UI with forms for login, create-account, list, transfer, deposit.

## Notes
- Uses `sessionStorage` to hold the JWT after login.
- Replace with a real SPA framework (React/Vue) when needed; the static
  delivery model still applies.
