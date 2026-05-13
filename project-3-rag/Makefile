# Project 3 — Document QA with Citations (RAG)
# Prerequisites:
#   1. shared-infra/ must be deployed
#   2. project-1-inference/ must be deployed (RAG calls into the vLLM gateway)
#
# Usage:
#   make apply         Apply Project 3's terraform (buckets + IAM)
#   make image         Build & push embeddings + query-api + ingestion images
#   make deploy        Deploy Qdrant + RAG services to the cluster
#   make smoke-test    End-to-end test: upload doc, ingest, query
#   make undeploy      Remove RAG workloads (terraform infra stays)
#   make tf-destroy    Destroy Project 3's buckets + IAM

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

K8S_DIR := kubernetes
TF_DIR := terraform
REGION ?= us-central1
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
CLUSTER_NAME ?= dev-genai-inference
REGISTRY ?= $(REGION)-docker.pkg.dev/$(PROJECT_ID)/vllm-platform

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: tf-init
tf-init: ## terraform init (project-3 stack)
	cd $(TF_DIR) && terraform init

.PHONY: tf-plan
tf-plan: ## terraform plan
	cd $(TF_DIR) && terraform plan -out=tfplan

.PHONY: apply
apply: ## terraform apply — create buckets + IAM
	cd $(TF_DIR) && terraform apply -auto-approve

.PHONY: tf-destroy
tf-destroy: ## terraform destroy — remove RAG buckets + IAM
	cd $(TF_DIR) && terraform destroy -auto-approve

.PHONY: image
image: ## Build & push embeddings + query-api + ingestion images
	docker build -t $(REGISTRY)/embeddings:0.1.0 docker/embeddings/
	docker push    $(REGISTRY)/embeddings:0.1.0
	docker build -t $(REGISTRY)/query-api:0.1.0 docker/query-api/
	docker push    $(REGISTRY)/query-api:0.1.0
	docker build -t $(REGISTRY)/ingestion:0.1.0 docker/ingestion/
	docker push    $(REGISTRY)/ingestion:0.1.0

.PHONY: deploy
deploy: ## Apply Kubernetes manifests
	./scripts/deploy.sh

.PHONY: undeploy
undeploy: ## Delete RAG workloads from the cluster
	-kubectl delete -f $(K8S_DIR)/observability/
	-kubectl delete -f $(K8S_DIR)/rag/
	-kubectl delete pvc -n qdrant --all || true
	-kubectl delete -f $(K8S_DIR)/qdrant/

.PHONY: smoke-test
smoke-test: ## End-to-end RAG test (upload, ingest, query)
	./scripts/smoke-test.sh

.PHONY: tests
tests: ## Run query-api unit tests
	cd tests/integration && pytest -v test_query_api.py
