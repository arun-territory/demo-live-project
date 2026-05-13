# ─────────────────────────────────────────────────────────────────────────────
# Private GenAI Inference Platform — Make targets
#
# Day-to-day commands:
#   make plan           Terraform plan
#   make apply          Terraform apply (infra: VPC, GKE, node pools, platform)
#   make deploy         kubectl apply the workload (vllm, gateway, monitoring)
#   make smoke-test     End-to-end curl against /v1/chat/completions
#   make load-test      Locust load against the endpoint
#   make destroy        Tear EVERYTHING down (billing-safe order)
#   make kubeconfig     Refresh local kubeconfig
#   make lint           tflint + yamllint + kubeval + hadolint
# ─────────────────────────────────────────────────────────────────────────────

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF_DIR := terraform
K8S_DIR := kubernetes
REGION ?= us-central1
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
CLUSTER_NAME ?= genai-inference

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ── Terraform ────────────────────────────────────────────────────────────────

.PHONY: init
init: ## terraform init
	cd $(TF_DIR) && terraform init

.PHONY: plan
plan: ## terraform plan
	cd $(TF_DIR) && terraform plan -out=tfplan

.PHONY: apply
apply: ## terraform apply (infra: VPC, GKE, node pools, platform addons)
	cd $(TF_DIR) && terraform apply -auto-approve
	$(MAKE) kubeconfig

.PHONY: destroy
destroy: ## DESTROY everything — node pools first (stop GPU billing fastest)
	@echo ">>> Scaling GPU node pool to zero first to stop billing..."
	-gcloud container node-pools resize gpu-pool \
		--cluster=$(CLUSTER_NAME) --region=$(REGION) --num-nodes=0 --quiet || true
	@echo ">>> Deleting RAG PVCs so the StorageClass disks go too..."
	-kubectl delete pvc -n qdrant --all --timeout=2m || true
	cd $(TF_DIR) && terraform destroy -auto-approve

.PHONY: kubeconfig
kubeconfig: ## Refresh local kubeconfig
	gcloud container clusters get-credentials $(CLUSTER_NAME) \
		--region=$(REGION) --project=$(PROJECT_ID)

# ── Workload deployment ──────────────────────────────────────────────────────

.PHONY: deploy
deploy: ## Apply all Kubernetes manifests in correct order (inference + RAG)
	./scripts/deploy.sh

.PHONY: deploy-inference
deploy-inference: ## Deploy only Project 1 (vLLM + gateway, no RAG)
	DEPLOY_RAG=false ./scripts/deploy.sh

.PHONY: deploy-rag
deploy-rag: ## Deploy only Project 3 (Qdrant + RAG services), assumes inference already up
	./scripts/deploy-rag.sh

.PHONY: undeploy
undeploy: ## Delete workload (keep platform / cluster)
	-kubectl delete -f $(K8S_DIR)/cost-controls/
	-kubectl delete -f $(K8S_DIR)/observability/
	-kubectl delete -f $(K8S_DIR)/rag/
	-kubectl delete -f $(K8S_DIR)/qdrant/
	-kubectl delete -f $(K8S_DIR)/gateway/
	-kubectl delete -f $(K8S_DIR)/vllm/

.PHONY: rag-smoke-test
rag-smoke-test: ## End-to-end RAG: upload sample doc, ingest, query
	./scripts/rag-smoke-test.sh

# ── Testing ──────────────────────────────────────────────────────────────────

.PHONY: smoke-test
smoke-test: ## End-to-end curl smoke test
	./scripts/smoke-test.sh

.PHONY: load-test
load-test: ## Locust load test
	python scripts/load-test.py

.PHONY: integration-test
integration-test: ## pytest integration suite
	cd tests/integration && pytest -v

# ── Quality gates ────────────────────────────────────────────────────────────

.PHONY: lint
lint: lint-tf lint-yaml lint-docker ## Run all linters

.PHONY: lint-tf
lint-tf:
	cd $(TF_DIR) && terraform fmt -check -recursive
	tflint --chdir=$(TF_DIR) || true

.PHONY: lint-yaml
lint-yaml:
	yamllint -d relaxed $(K8S_DIR)/ || true
	find $(K8S_DIR) -name '*.yaml' -exec kubeval --strict {} \; || true

.PHONY: lint-docker
lint-docker:
	hadolint docker/apikey-gateway/Dockerfile || true
	hadolint docker/embeddings/Dockerfile      || true
	hadolint docker/query-api/Dockerfile       || true
	hadolint docker/ingestion/Dockerfile       || true

# ── Bootstrap ────────────────────────────────────────────────────────────────

.PHONY: bootstrap
bootstrap: ## First-time setup: enable APIs, create tfstate bucket, request GPU quota
	./scripts/bootstrap.sh
