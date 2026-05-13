"""
Locust load test against the OpenAI-compatible endpoint.

Run:
    pip install locust
    INFERENCE_HOST=https://llm.internal.example.com API_KEY=xxx \
        locust -f scripts/load-test.py --headless -u 20 -r 2 -t 5m

Reports: requests/sec, P50/P95/P99 latency. Pair with the Grafana dashboard.
"""
from __future__ import annotations

import os
import random

from locust import HttpUser, between, task

PROMPTS = [
    "Summarise the DPDP Act in 3 bullets.",
    "Write a Python function that reverses a string.",
    "Explain PagedAttention in 2 sentences.",
    "List 5 ways to reduce LLM serving cost on Kubernetes.",
    "What's the difference between TTFT and end-to-end latency?",
]


class InferenceUser(HttpUser):
    host = os.environ.get("INFERENCE_HOST", "http://localhost:8080")
    wait_time = between(0.5, 2.0)

    def on_start(self):
        key = os.environ.get("API_KEY")
        if not key:
            raise RuntimeError("Set API_KEY env var")
        self.client.headers.update({"X-API-Key": key, "Content-Type": "application/json"})

    @task
    def chat_completion(self):
        payload = {
            "model": "google/gemma-2-9b-it",
            "messages": [{"role": "user", "content": random.choice(PROMPTS)}],
            "max_tokens": 128,
            "temperature": 0.7,
        }
        with self.client.post(
            "/v1/chat/completions", json=payload, catch_response=True, name="/v1/chat/completions"
        ) as r:
            if r.status_code != 200:
                r.failure(f"status={r.status_code} body={r.text[:200]}")
