"""
Tiny FastAPI proxy that validates an X-API-Key header against a key file
(populated by External Secrets from GCP Secret Manager), then streams the
request to the upstream vLLM service.

Exposes Prometheus metrics on a separate port so it can be scraped without
exposing them on the public ingress path.
"""
from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from prometheus_client import Counter, Histogram, start_http_server

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
UPSTREAM_URL = os.environ["UPSTREAM_URL"].rstrip("/")
API_KEYS_FILE = Path(os.environ.get("API_KEYS_FILE", "/etc/api-keys/keys"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))
REQUEST_TIMEOUT_SECONDS = float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "300"))

logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("apikey-gateway")

REQ_TOTAL = Counter(
    "apikey_gateway_requests_total",
    "Requests handled by the gateway",
    ["method", "path", "status"],
)
REQ_LATENCY = Histogram(
    "apikey_gateway_request_duration_seconds",
    "End-to-end gateway latency (excludes streaming body time)",
    ["path"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60),
)
AUTH_FAILURES = Counter(
    "apikey_gateway_auth_failures_total",
    "Requests rejected for invalid or missing API key",
    ["reason"],
)


class KeyStore:
    """File-backed API key store. Re-reads on every check — the file is small
    and updates are infrequent. Keeps the gateway stateless."""

    def __init__(self, path: Path):
        self.path = path

    def valid(self, key: str | None) -> bool:
        if not key:
            return False
        try:
            keys = {line.strip() for line in self.path.read_text().splitlines() if line.strip()}
        except FileNotFoundError:
            log.error("API key file %s not found", self.path)
            return False
        return key in keys


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.keys = KeyStore(API_KEYS_FILE)
    app.state.http = httpx.AsyncClient(
        base_url=UPSTREAM_URL,
        timeout=httpx.Timeout(REQUEST_TIMEOUT_SECONDS, connect=5.0),
    )
    start_http_server(METRICS_PORT)
    log.info("Gateway ready — upstream=%s, metrics on :%s", UPSTREAM_URL, METRICS_PORT)
    yield
    await app.state.http.aclose()


app = FastAPI(lifespan=lifespan, title="vLLM API-Key Gateway", version="0.1.0")


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz(request: Request):
    # We're ready if we can read the key file. Don't probe upstream on every
    # readyz — that creates a thundering herd during vLLM cold-starts.
    if not API_KEYS_FILE.exists():
        raise HTTPException(503, "api key file missing")
    return {"status": "ready"}


@app.api_route(
    "/{full_path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
)
async def proxy(full_path: str, request: Request):
    start = time.perf_counter()
    path = "/" + full_path

    # Public health endpoints are served by this process. Anything else needs auth.
    api_key = request.headers.get("X-API-Key") or _bearer(request.headers.get("Authorization"))
    if not request.app.state.keys.valid(api_key):
        AUTH_FAILURES.labels(reason="invalid_or_missing").inc()
        REQ_TOTAL.labels(request.method, path, "401").inc()
        raise HTTPException(401, "invalid or missing API key")

    # Strip hop-by-hop and our auth header before forwarding.
    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in {"host", "x-api-key", "authorization", "content-length"}
    }

    body = await request.body()
    upstream = await request.app.state.http.request(
        request.method, path, content=body, headers=headers, params=request.query_params,
    )

    REQ_TOTAL.labels(request.method, path, str(upstream.status_code)).inc()
    REQ_LATENCY.labels(path).observe(time.perf_counter() - start)

    # Stream the response back unchanged so token-streaming endpoints work.
    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        headers={k: v for k, v in upstream.headers.items() if k.lower() != "content-encoding"},
        media_type=upstream.headers.get("content-type"),
    )


def _bearer(auth_header: str | None) -> str | None:
    if not auth_header:
        return None
    parts = auth_header.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1].strip()
    return None


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level=LOG_LEVEL.lower())
