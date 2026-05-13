"""
Embedding service.
POST /embed   {"texts": ["...", "..."]}  -> {"embeddings": [[...], [...]]}
GET  /healthz, /readyz
Prometheus on a separate port (default 9100).
"""
from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from prometheus_client import Counter, Histogram, start_http_server
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer

MODEL_NAME = os.environ.get("MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
PORT = int(os.environ.get("PORT", "8080"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("embeddings")

EMBED_REQUESTS = Counter("embed_requests_total", "Embedding requests", ["status"])
EMBED_LATENCY = Histogram("embed_latency_seconds", "Embedding latency seconds")
EMBED_BATCH_SIZE = Histogram(
    "embed_batch_size", "Texts per request",
    buckets=(1, 2, 4, 8, 16, 32, 64, 128, 256),
)


class EmbedRequest(BaseModel):
    texts: list[str] = Field(..., min_length=1, max_length=256)


class EmbedResponse(BaseModel):
    embeddings: list[list[float]]
    model: str
    dim: int


@asynccontextmanager
async def lifespan(app: FastAPI):
    if METRICS_PORT > 0:
        start_http_server(METRICS_PORT)
        log.info("metrics server on :%d", METRICS_PORT)
    log.info("loading model: %s", MODEL_NAME)
    app.state.model = SentenceTransformer(MODEL_NAME, cache_folder=os.environ.get("HF_HOME"))
    app.state.dim = app.state.model.get_sentence_embedding_dimension()
    log.info("model ready, dim=%d", app.state.dim)
    yield


app = FastAPI(title="embeddings", lifespan=lifespan)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    if not hasattr(app.state, "model"):
        raise HTTPException(503, "model not loaded")
    return {"status": "ready", "model": MODEL_NAME, "dim": app.state.dim}


@app.post("/embed", response_model=EmbedResponse)
async def embed(req: EmbedRequest):
    start = time.perf_counter()
    try:
        vecs = app.state.model.encode(
            req.texts,
            normalize_embeddings=True,
            convert_to_numpy=True,
        )
        EMBED_REQUESTS.labels(status="ok").inc()
        EMBED_BATCH_SIZE.observe(len(req.texts))
        return EmbedResponse(
            embeddings=vecs.tolist(),
            model=MODEL_NAME,
            dim=int(app.state.dim),
        )
    except Exception:
        EMBED_REQUESTS.labels(status="error").inc()
        log.exception("embed failed")
        raise HTTPException(500, "embed failed")
    finally:
        EMBED_LATENCY.observe(time.perf_counter() - start)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
