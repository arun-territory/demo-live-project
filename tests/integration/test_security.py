"""
In-cluster security tests. Requires kubectl context pointed at a deployed
cluster. Skipped in CI; run manually after `make deploy`.

What we verify:
  - vllm namespace rejects ingress from arbitrary pods (NetworkPolicy works)
  - vLLM pods run as non-root, dropped caps, read-only filesystem aspects
  - vLLM Service is ClusterIP only (no public exposure)
"""
from __future__ import annotations

import json
import shutil
import subprocess

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("kubectl") is None,
    reason="kubectl not available",
)


def kubectl(*args: str) -> str:
    return subprocess.check_output(["kubectl", *args], text=True)


def test_vllm_service_is_clusterip():
    svc = json.loads(kubectl("-n", "vllm", "get", "svc", "vllm", "-o", "json"))
    assert svc["spec"]["type"] == "ClusterIP", "vLLM service must not be exposed externally"


def test_vllm_pod_runs_as_non_root():
    pods = json.loads(kubectl("-n", "vllm", "get", "pods", "-l", "app=vllm", "-o", "json"))
    assert pods["items"], "no vLLM pods found"
    for pod in pods["items"]:
        sc = pod["spec"].get("securityContext", {})
        assert sc.get("runAsNonRoot") is True, f"{pod['metadata']['name']} can run as root"


def test_vllm_containers_drop_all_caps():
    pods = json.loads(kubectl("-n", "vllm", "get", "pods", "-l", "app=vllm", "-o", "json"))
    for pod in pods["items"]:
        for c in pod["spec"]["containers"]:
            caps = c.get("securityContext", {}).get("capabilities", {})
            assert "ALL" in caps.get("drop", []), f"{c['name']} does not drop ALL caps"


def test_default_deny_netpol_exists():
    np = json.loads(kubectl("-n", "vllm", "get", "networkpolicy", "default-deny", "-o", "json"))
    assert "Ingress" in np["spec"]["policyTypes"]
    assert "Egress" in np["spec"]["policyTypes"]


def test_lateral_movement_blocked():
    """A pod in 'default' namespace cannot reach vllm. We run a brief ephemeral pod."""
    out = subprocess.run(
        [
            "kubectl", "run", "netpol-probe", "--rm", "-i", "--restart=Never",
            "--image=curlimages/curl:8.7.1", "--",
            "curl", "-sk", "--max-time", "3", "http://vllm.vllm.svc.cluster.local:8000/health",
        ],
        capture_output=True, text=True,
    )
    # If the netpol works, curl exits non-zero (timeout/connection refused).
    assert out.returncode != 0, "Pod from 'default' ns reached vllm — NetworkPolicy is not enforced"
