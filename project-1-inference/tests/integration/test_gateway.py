"""
Unit/integration tests for the API-key gateway.
Spins up the FastAPI app in-process; mocks the upstream with httpx's MockTransport.
"""
from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

import httpx
import pytest

# Make the gateway importable
GATEWAY_DIR = Path(__file__).resolve().parents[2] / "docker" / "apikey-gateway"
sys.path.insert(0, str(GATEWAY_DIR))


@pytest.fixture
def keys_file(tmp_path):
    f = tmp_path / "keys"
    f.write_text("valid-key-1\nvalid-key-2\n")
    return f


@pytest.fixture
def app(monkeypatch, keys_file):
    monkeypatch.setenv("UPSTREAM_URL", "http://upstream.test")
    monkeypatch.setenv("API_KEYS_FILE", str(keys_file))
    monkeypatch.setenv("METRICS_PORT", "0")
    # Reimport to pick up env vars
    if "main" in sys.modules:
        del sys.modules["main"]
    main = importlib.import_module("main")
    return main.app


@pytest.fixture
def client(app):
    # Lifespan is not entered with TestClient; set state manually.
    from fastapi.testclient import TestClient
    import main as gw_main

    transport = httpx.MockTransport(_upstream)
    app.state.keys = gw_main.KeyStore(Path(os.environ["API_KEYS_FILE"]))
    app.state.http = httpx.AsyncClient(base_url=os.environ["UPSTREAM_URL"], transport=transport)
    with TestClient(app) as c:
        yield c


def _upstream(request: httpx.Request) -> httpx.Response:
    if request.url.path == "/v1/models":
        return httpx.Response(200, json={"data": [{"id": "google/gemma-2-9b-it"}]})
    if request.url.path == "/v1/chat/completions":
        return httpx.Response(
            200,
            json={
                "id": "test",
                "object": "chat.completion",
                "choices": [{"message": {"role": "assistant", "content": "pong"}}],
            },
        )
    return httpx.Response(404)


def test_healthz_no_auth(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_readyz_no_auth(client):
    r = client.get("/readyz")
    assert r.status_code == 200


def test_missing_api_key_is_401(client):
    r = client.get("/v1/models")
    assert r.status_code == 401


def test_invalid_api_key_is_401(client):
    r = client.get("/v1/models", headers={"X-API-Key": "wrong"})
    assert r.status_code == 401


def test_valid_api_key_forwards(client):
    r = client.get("/v1/models", headers={"X-API-Key": "valid-key-1"})
    assert r.status_code == 200
    assert r.json()["data"][0]["id"] == "google/gemma-2-9b-it"


def test_bearer_header_also_works(client):
    r = client.get("/v1/models", headers={"Authorization": "Bearer valid-key-2"})
    assert r.status_code == 200


def test_chat_completions_proxied(client):
    r = client.post(
        "/v1/chat/completions",
        headers={"X-API-Key": "valid-key-1"},
        json={"model": "x", "messages": [{"role": "user", "content": "ping"}]},
    )
    assert r.status_code == 200
    assert r.json()["choices"][0]["message"]["content"] == "pong"
