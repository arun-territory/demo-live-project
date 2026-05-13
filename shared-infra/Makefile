# Shared infrastructure — the empty Kubernetes cluster.
# Run this BEFORE deploying either project.
#
# Usage:
#   make apply        Build the cluster (~15 min)
#   make destroy      Tear it all down
#   make kubeconfig   Point kubectl at the new cluster
#   make plan         Show what would change

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF_DIR := terraform
REGION ?= us-central1
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
CLUSTER_NAME ?= dev-genai-inference

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: init
init: ## terraform init
	cd $(TF_DIR) && terraform init

.PHONY: plan
plan: ## terraform plan
	cd $(TF_DIR) && terraform plan -out=tfplan

.PHONY: apply
apply: ## terraform apply — build the cluster
	cd $(TF_DIR) && terraform apply -auto-approve
	$(MAKE) kubeconfig

.PHONY: destroy
destroy: ## terraform destroy — tear EVERYTHING down (cluster + VPC)
	@echo ">>> Scaling GPU pool to 0 first to stop billing fast..."
	-gcloud container node-pools resize gpu-pool \
		--cluster=$(CLUSTER_NAME) --region=$(REGION) --num-nodes=0 --quiet || true
	cd $(TF_DIR) && terraform destroy -auto-approve

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the new cluster
	gcloud container clusters get-credentials $(CLUSTER_NAME) \
		--region=$(REGION) --project=$(PROJECT_ID)

.PHONY: fmt
fmt: ## terraform fmt
	cd $(TF_DIR) && terraform fmt -recursive

.PHONY: validate
validate: ## terraform validate
	cd $(TF_DIR) && terraform validate
