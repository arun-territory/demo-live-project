"""
End-to-end integration tests.
Requires a running inference API at INFERENCE_API_URL (default: http://localhost:8080).
Run with: pytest tests/integration/ -v
"""
import os
import pytest
import httpx

BASE_URL = os.environ.get("INFERENCE_API_URL", "http://localhost:8080")


@pytest.fixture(scope="session")
def client():
    with httpx.Client(base_url=BASE_URL, timeout=30) as c:
        yield c


def test_health_liveness(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_health_readiness(client):
    response = client.get("/readyz")
    assert response.status_code in (200, 503)


def test_list_models_returns_list(client):
    response = client.get("/v1/models")
    assert response.status_code == 200
    body = response.json()
    assert "models" in body
    assert isinstance(body["models"], list)


def test_echo_inference_roundtrip(client):
    payload = {
        "model_name": "echo",
        "model_version": "latest",
        "inputs": [
            {"name": "tensor0", "data": [1, 2, 3, 4], "shape": [4], "datatype": "FP32"}
        ],
    }
    response = client.post("/v1/infer", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["model_name"] == "echo"
    assert body["outputs"][0]["data"] == [1, 2, 3, 4]


def test_metrics_endpoint_returns_prometheus_format(client):
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "inference_requests_total" in response.text
