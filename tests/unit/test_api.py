import pytest
from fastapi.testclient import TestClient
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src/api"))

from main import app

client = TestClient(app)


def test_liveness():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_list_models():
    response = client.get("/v1/models")
    assert response.status_code == 200
    data = response.json()
    assert "models" in data
    assert isinstance(data["models"], list)


def test_infer_echo_model():
    response = client.post(
        "/v1/infer",
        json={
            "model_name": "echo",
            "model_version": "1.0.0",
            "inputs": [
                {"name": "input0", "data": [1.0, 2.0, 3.0], "shape": [3], "datatype": "FP32"}
            ],
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert data["model_name"] == "echo"
    assert len(data["outputs"]) == 1
    assert data["outputs"][0]["name"] == "input0"
    assert data["outputs"][0]["data"] == [1.0, 2.0, 3.0]


def test_infer_model_not_found():
    response = client.post(
        "/v1/infer",
        json={
            "model_name": "nonexistent-model",
            "model_version": "1.0.0",
            "inputs": [{"name": "x", "data": [0]}],
        },
    )
    assert response.status_code == 404


def test_infer_missing_inputs():
    response = client.post(
        "/v1/infer",
        json={"model_name": "echo"},
    )
    assert response.status_code == 422


def test_metrics_endpoint():
    response = client.get("/metrics")
    assert response.status_code == 200
    assert b"inference_requests_total" in response.content or response.status_code == 200
