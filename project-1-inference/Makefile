# Project 1 — Private LLM Inference
# Prerequisites: shared-infra/ must be deployed first.
#
# Usage:
#   make deploy        Deploy vLLM + gateway + observability + cost-controls
#   make undeploy      Remove everything from the cluster (cluster stays)
#   make smoke-test    End-to-end curl test
#   make load-test     Locust load test
#   make image         Build and push the gateway image
#   make tests         Run unit tests for the gateway

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

K8S_DIR := kubernetes
REGION ?= us-central1
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
CLUSTER_NAME ?= dev-genai-inference
REGISTRY ?= $(REGION)-docker.pkg.dev/$(PROJECT_ID)/vllm-platform

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: deploy
deploy: ## Apply all manifests (vLLM, gateway, observability, cost-controls)
	./scripts/deploy.sh

.PHONY: undeploy
undeploy: ## Delete all workloads from the cluster
	-kubectl delete -f $(K8S_DIR)/cost-controls/
	-kubectl delete -f $(K8S_DIR)/observability/
	-kubectl delete -f $(K8S_DIR)/gateway/
	-kubectl delete -f $(K8S_DIR)/vllm/

.PHONY: smoke-test
smoke-test: ## End-to-end curl smoke test
	./scripts/smoke-test.sh

.PHONY: load-test
load-test: ## Locust load test
	python scripts/load-test.py

.PHONY: image
image: ## Build and push the gateway image
	docker build -t $(REGISTRY)/apikey-gateway:0.1.0 docker/apikey-gateway/
	docker push $(REGISTRY)/apikey-gateway:0.1.0

.PHONY: tests
tests: ## Run gateway unit tests
	cd tests/integration && pytest -v test_gateway.py
