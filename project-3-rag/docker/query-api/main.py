"""
RAG query API.

Per request:
  1. Validate X-API-Key (or Authorization: Bearer) against rag-api-keys
  2. Embed the user query
  3. Vector search Qdrant
  4. Build a prompt with retrieved chunks
  5. POST to vLLM gateway with the upstream key
  6. Return {answer, citations[]}
"""
from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.security.utils import get_authorization_scheme_param
from prometheus_client import Counter, Histogram, start_http_server
from pydantic import BaseModel, Field

PORT = int(os.environ.get("PORT", "8080"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))
API_KEYS_FILE = Path(os.environ.get("API_KEYS_FILE", "/etc/api-keys/keys"))

EMBEDDINGS_URL = os.environ["EMBEDDINGS_URL"]
QDRANT_URL = os.environ["QDRANT_URL"]
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "documents")
QDRANT_API_KEY = os.environ["QDRANT_API_KEY"]
VLLM_GATEWAY_URL = os.environ["VLLM_GATEWAY_URL"]
VLLM_MODEL = os.environ.get("VLLM_MODEL", "google/gemma-2-9b-it")
VLLM_API_KEY = os.environ["VLLM_API_KEY"]
TOP_K = int(os.environ.get("TOP_K", "5"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("query-api")

REQS = Counter("rag_queries_total", "Queries", ["status"])
AUTH_FAIL = Counter("rag_auth_failures_total", "Auth failures")
LATENCY = Histogram(
    "rag_query_latency_seconds", "End-to-end query latency seconds",
    buckets=(0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32),
)
STAGE_LATENCY = Histogram(
    "rag_stage_latency_seconds", "Per-stage latency", ["stage"],
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16),
)
RETRIEVED = Histogram(
    "rag_retrieved_chunks", "Chunks retrieved per query",
    buckets=(0, 1, 2, 3, 5, 10, 20),
)


class KeyStore:
    """Re-reads the keys file on every check so ESO rotations apply instantly."""

    def __init__(self, path: Path):
        self.path = path

    def is_valid(self, key: str) -> bool:
        if not key or not self.path.exists():
            return False
        keys = {ln.strip() for ln in self.path.read_text().splitlines() if ln.strip()}
        return key in keys


def _extract_key(request: Request) -> str:
    key = request.headers.get("x-api-key", "").strip()
    if key:
        return key
    scheme, value = get_authorization_scheme_param(request.headers.get("authorization", ""))
    if scheme.lower() == "bearer":
        return value.strip()
    return ""


async def require_key(request: Request) -> None:
    key = _extract_key(request)
    if not app.state.keys.is_valid(key):
        AUTH_FAIL.inc()
        raise HTTPException(401, "invalid or missing api key")


class QueryRequest(BaseModel):
    query: str = Field(..., min_length=1, max_length=4000)
    top_k: int | None = Field(None, ge=1, le=20)
    filters: dict[str, Any] | None = None
    max_tokens: int = Field(512, ge=16, le=2048)
    temperature: float = Field(0.2, ge=0.0, le=2.0)


class Citation(BaseModel):
    source: str
    chunk_index: int
    score: float
    snippet: str


class QueryResponse(BaseModel):
    answer: str
    citations: list[Citation]
    model: str


PROMPT_TEMPLATE = """You are a helpful assistant. Answer the question using ONLY the context below.
If the answer isn't in the context, say "I don't know based on the provided documents."
Cite sources inline as [n] matching the context numbers.

Context:
{context}

Question: {question}

Answer:"""


@asynccontextmanager
async def lifespan(app: FastAPI):
    if METRICS_PORT > 0:
        start_http_server(METRICS_PORT)
    app.state.keys = KeyStore(API_KEYS_FILE)
    app.state.http = httpx.AsyncClient(timeout=httpx.Timeout(60.0, connect=5.0))
    log.info("query-api ready; embeddings=%s qdrant=%s vllm=%s",
             EMBEDDINGS_URL, QDRANT_URL, VLLM_GATEWAY_URL)
    try:
        yield
    finally:
        await app.state.http.aclose()


app = FastAPI(title="rag-query-api", lifespan=lifespan)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    if not API_KEYS_FILE.exists():
        raise HTTPException(503, "keys file not mounted")
    return {"status": "ready"}


async def _embed(text: str) -> list[float]:
    t0 = time.perf_counter()
    r = await app.state.http.post(
        f"{EMBEDDINGS_URL}/embed", json={"texts": [text]},
    )
    r.raise_for_status()
    STAGE_LATENCY.labels(stage="embed").observe(time.perf_counter() - t0)
    return r.json()["embeddings"][0]


async def _search(vector: list[float], top_k: int, filters: dict | None) -> list[dict]:
    t0 = time.perf_counter()
    payload: dict[str, Any] = {
        "vector": vector,
        "limit": top_k,
        "with_payload": True,
    }
    if filters:
        payload["filter"] = filters
    r = await app.state.http.post(
        f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/search",
        json=payload,
        headers={"api-key": QDRANT_API_KEY},
    )
    r.raise_for_status()
    STAGE_LATENCY.labels(stage="retrieve").observe(time.perf_counter() - t0)
    return r.json().get("result", [])


async def _generate(prompt: str, max_tokens: int, temperature: float) -> str:
    t0 = time.perf_counter()
    r = await app.state.http.post(
        f"{VLLM_GATEWAY_URL}/v1/chat/completions",
        headers={"X-API-Key": VLLM_API_KEY, "Content-Type": "application/json"},
        json={
            "model": VLLM_MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": temperature,
        },
    )
    r.raise_for_status()
    STAGE_LATENCY.labels(stage="generate").observe(time.perf_counter() - t0)
    return r.json()["choices"][0]["message"]["content"]


@app.post("/query", response_model=QueryResponse, dependencies=[Depends(require_key)])
async def query(req: QueryRequest):
    start = time.perf_counter()
    try:
        top_k = req.top_k or TOP_K
        vec = await _embed(req.query)
        hits = await _search(vec, top_k=top_k, filters=req.filters)
        RETRIEVED.observe(len(hits))

        citations: list[Citation] = []
        context_parts: list[str] = []
        for i, h in enumerate(hits, start=1):
            payload = h.get("payload") or {}
            src = payload.get("source", "unknown")
            idx = int(payload.get("chunk_index", 0))
            text = payload.get("text", "")
            citations.append(Citation(
                source=src, chunk_index=idx,
                score=float(h.get("score", 0.0)),
                snippet=text[:200],
            ))
            context_parts.append(f"[{i}] (from {src}, chunk {idx})\n{text}")

        if not context_parts:
            REQS.labels(status="empty").inc()
            return QueryResponse(
                answer="I don't know based on the provided documents.",
                citations=[],
                model=VLLM_MODEL,
            )

        prompt = PROMPT_TEMPLATE.format(
            context="\n\n".join(context_parts),
            question=req.query,
        )
        answer = await _generate(prompt, req.max_tokens, req.temperature)
        REQS.labels(status="ok").inc()
        return QueryResponse(answer=answer, citations=citations, model=VLLM_MODEL)
    except httpx.HTTPStatusError as e:
        REQS.labels(status=f"upstream_{e.response.status_code}").inc()
        log.exception("upstream error")
        raise HTTPException(502, f"upstream error: {e.response.status_code}")
    except Exception:
        REQS.labels(status="error").inc()
        log.exception("query failed")
        raise HTTPException(500, "query failed")
    finally:
        LATENCY.observe(time.perf_counter() - start)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
