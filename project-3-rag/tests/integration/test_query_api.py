"""
Unit/integration tests for the RAG query API.
In-process FastAPI; embeddings, Qdrant, and vLLM gateway are all mocked
with httpx.MockTransport.
"""
from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

import httpx
import pytest

QUERY_API_DIR = Path(__file__).resolve().parents[2] / "docker" / "query-api"
sys.path.insert(0, str(QUERY_API_DIR))


@pytest.fixture
def keys_file(tmp_path):
    f = tmp_path / "rag-keys"
    f.write_text("rag-key-1\nrag-key-2\n")
    return f


@pytest.fixture
def env(monkeypatch, keys_file):
    monkeypatch.setenv("API_KEYS_FILE", str(keys_file))
    monkeypatch.setenv("EMBEDDINGS_URL", "http://embeddings.test")
    monkeypatch.setenv("QDRANT_URL", "http://qdrant.test")
    monkeypatch.setenv("QDRANT_API_KEY", "qdrant-secret")
    monkeypatch.setenv("VLLM_GATEWAY_URL", "http://gateway.test")
    monkeypatch.setenv("VLLM_API_KEY", "vllm-secret")
    monkeypatch.setenv("METRICS_PORT", "0")
    if "main" in sys.modules:
        del sys.modules["main"]
    return importlib.import_module("main")


def _mock_handler(request: httpx.Request) -> httpx.Response:
    host = request.url.host
    path = request.url.path
    if host == "embeddings.test" and path == "/embed":
        body = request.json()
        return httpx.Response(200, json={
            "embeddings": [[0.1] * 384 for _ in body["texts"]],
            "model": "test", "dim": 384,
        })
    if host == "qdrant.test" and path.endswith("/points/search"):
        return httpx.Response(200, json={"result": [
            {
                "id": "1", "score": 0.91,
                "payload": {
                    "source": "doc1.txt", "chunk_index": 0,
                    "text": "Project Falcon has a budget of $4.2M.",
                },
            },
            {
                "id": "2", "score": 0.87,
                "payload": {
                    "source": "doc1.txt", "chunk_index": 1,
                    "text": "Technical lead: Priya Subramanian.",
                },
            },
        ]})
    if host == "gateway.test" and path == "/v1/chat/completions":
        return httpx.Response(200, json={
            "choices": [{"message": {"content": "Budget is $4.2M, led by Priya [1][2]."}}],
        })
    return httpx.Response(404, json={"err": f"no mock for {host}{path}"})


@pytest.fixture
def client(env):
    from fastapi.testclient import TestClient
    transport = httpx.MockTransport(_mock_handler)
    env.app.state.keys = env.KeyStore(Path(os.environ["API_KEYS_FILE"]))
    env.app.state.http = httpx.AsyncClient(transport=transport, timeout=10.0)
    with TestClient(env.app) as c:
        yield c


def test_healthz_no_auth(client):
    r = client.get("/healthz")
    assert r.status_code == 200


def test_readyz_no_auth(client):
    r = client.get("/readyz")
    assert r.status_code == 200


def test_query_requires_auth(client):
    r = client.post("/query", json={"query": "anything"})
    assert r.status_code == 401


def test_query_rejects_invalid_key(client):
    r = client.post("/query",
                    headers={"X-API-Key": "wrong"},
                    json={"query": "anything"})
    assert r.status_code == 401


def test_query_end_to_end(client):
    r = client.post(
        "/query",
        headers={"X-API-Key": "rag-key-1"},
        json={"query": "What is Project Falcon's budget?"},
    )
    assert r.status_code == 200
    body = r.json()
    assert "4.2M" in body["answer"]
    assert len(body["citations"]) == 2
    assert body["citations"][0]["source"] == "doc1.txt"


def test_query_with_bearer_token(client):
    r = client.post(
        "/query",
        headers={"Authorization": "Bearer rag-key-2"},
        json={"query": "anything"},
    )
    assert r.status_code == 200


def test_query_empty_retrieval_returns_idk(client, monkeypatch):
    # Re-bind transport to return no hits
    def empty_handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/points/search"):
            return httpx.Response(200, json={"result": []})
        return _mock_handler(request)

    import main as m
    m.app.state.http = httpx.AsyncClient(
        transport=httpx.MockTransport(empty_handler), timeout=10.0,
    )
    r = client.post(
        "/query",
        headers={"X-API-Key": "rag-key-1"},
        json={"query": "nothing relevant"},
    )
    assert r.status_code == 200
    assert "don't know" in r.json()["answer"].lower()
    assert r.json()["citations"] == []
